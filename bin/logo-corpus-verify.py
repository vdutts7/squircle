#!/usr/bin/env python3
"""Branch B verify: silent-self-verify-or-omit.

For each in-scope slug:
  - Load raw/<slug>/<nn>-<source>.<ext> + .meta.json
  - Render each through squircle.sh to temp webp
  - Compute phash per rendered webp
  - Cluster by Hamming <= 10 across tiers
  - Decision table:
      no renders       → fail_exhausted
      tier 1 solo      → pass_authoritative      (wikipedia)
      tier 4 solo      → pass_authoritative      (models_dev)
      cross-tier cluster (>=2 tiers) → pass_cluster
      tier 2|3|5|6 solo → fail_low_confidence    (NOT queued; omitted)
  - Winner within accepting set: highest-priority tier
  - Writes ledger/<slug>.json

No eyeball. No queue. No ask.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
REG = REPO / "registry" / "logo-corpus"
SLUGS_PATH = REG / "slugs.json"
RAW_ROOT = REG / "raw"
LEDGER = REG / "ledger"
BAD = REG / "known-bad-anchors.json"
SQUIRCLE_SH = REPO / "bin" / "squircle.sh"
PHASH_PICK = REPO / "bin" / "phash-pick.zsh"

CLUSTER_T = 10

TIER_PRIORITY = {
    "wikipedia": 10,
    "models_dev": 9,
    "github": 7,
    "twitter": 6,
    "favicon": 4,
    "bing_image": 2,
}
AUTHORITATIVE_SOLO = {"wikipedia", "models_dev"}


def shim(msg: str, fix: str, code: int = 60) -> None:
    sys.stderr.write(f"🔴 logo-corpus-verify: {msg} (exit {code})\n  run: {fix}\n")
    sys.exit(code)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def phash_file(path: Path) -> str | None:
    try:
        from PIL import Image
        import imagehash
        return str(imagehash.phash(Image.open(str(path))))
    except Exception:
        return None


def hamming(a: str, b: str) -> int:
    if not a or not b:
        return 999
    try:
        return bin(int(a, 16) ^ int(b, 16)).count("1")
    except Exception:
        return 999


def render(src: Path, out_webp: Path) -> bool:
    """Render src to webp for phash. Postcheck disabled — we gate on pixel clustering,
    not render-quality. Phase 6 handles pixel-level correctness on the published winner.
    """
    env = os.environ.copy()
    env["SQUIRCLE_AUTO_PLAN"] = "1"
    env["SQUIRCLE_POSTCHECK"] = "0"
    try:
        subprocess.run(
            [str(SQUIRCLE_SH), "-q", str(src), "--out", str(out_webp)],
            capture_output=True, text=True, timeout=90, env=env,
        )
    except Exception as e:
        sys.stderr.write(f"[render] {src}: {e}\n")
        return False
    return out_webp.is_file() and out_webp.stat().st_size > 1000



def verify_slug(slug: str, bad_sha: set, bad_phash: list, bad_T: int) -> dict:
    row: dict = {"slug": slug, "verify_status": "fail_exhausted", "timestamp": int(time.time())}
    d = RAW_ROOT / slug
    if not d.is_dir():
        return row
    if (d / "FAIL.json").is_file():
        return row

    artifacts = sorted(
        p for p in d.iterdir()
        if p.is_file() and not p.name.endswith(".meta.json") and p.name != "FAIL.json"
    )
    if not artifacts:
        return row

    tmp_dir = Path(tempfile.mkdtemp(prefix=f"lcv-{slug}-"))
    renders: list[dict] = []
    try:
        for a in artifacts:
            m = re.match(r"^(\d+)-([a-z_]+)\.", a.name)
            if not m:
                continue
            idx, source = int(m.group(1)), m.group(2)
            out_webp = tmp_dir / f"{a.stem}.webp"
            if not render(a, out_webp):
                continue
            ph = phash_file(out_webp)
            if ph is None:
                continue
            renders.append({
                "idx": idx,
                "source": source,
                "tier_priority": TIER_PRIORITY.get(source, 0),
                "src_path": str(a),
                "src_sha256": sha256_bytes(a.read_bytes()),
                "render_path": str(out_webp),
                "render_sha256": sha256_bytes(out_webp.read_bytes()),
                "phash": ph,
            })

        if not renders:
            row["verify_status"] = "fail_exhausted"
            return row

        # Reject known-bad per-render
        clean = []
        for r in renders:
            if r["render_sha256"] in bad_sha or r["src_sha256"] in bad_sha:
                continue
            if any(hamming(r["phash"], bp) <= bad_T for bp in bad_phash):
                continue
            clean.append(r)
        if not clean:
            row["verify_status"] = "fail_known_bad"
            return row

        # Cluster
        clusters: list[list[int]] = []
        for i, r in enumerate(clean):
            placed = False
            for c in clusters:
                if any(hamming(r["phash"], clean[j]["phash"]) <= CLUSTER_T for j in c):
                    c.append(i); placed = True; break
            if not placed:
                clusters.append([i])

        def emit(w: dict, status: str, cluster_sources: list[str], cluster_size: int) -> dict:
            durable = REG / "renders" / f"{slug}.webp"
            durable.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(w["render_path"], durable)
            row.update({
                "verify_status": status,
                "winner_source": w["source"],
                "winner_sha256": w["render_sha256"],
                "output_phash": w["phash"],
                "render_path": str(durable),
                "cluster_sources": cluster_sources,
                "cluster_size": cluster_size,
            })
            return row

        # Precedence rule: authoritative-tier presence outranks lower-tier clusters.
        # 1) wikipedia present AND clean → pass; prefer its cluster if it has one.
        for src in ("wikipedia", "models_dev"):
            matches = [r for r in clean if r["source"] == src]
            if not matches:
                continue
            # Find the cluster containing this authoritative render.
            auth_render = matches[0]
            auth_idx = clean.index(auth_render)
            auth_cluster = next((c for c in clusters if auth_idx in c), [auth_idx])
            cluster_sources = sorted({clean[i]["source"] for i in auth_cluster})
            status = "pass_cluster" if len(cluster_sources) >= 2 else "pass_authoritative"
            return emit(auth_render, status, cluster_sources, len(auth_cluster))

        # No authoritative tier available. Accept cross-tier cluster among tiers 2/3/5.
        best_cluster = None
        for c in clusters:
            sources = {clean[i]["source"] for i in c}
            if len(sources) >= 2:
                if best_cluster is None or len(c) > len(best_cluster):
                    best_cluster = c
        if best_cluster:
            winner_idx = max(best_cluster, key=lambda i: clean[i]["tier_priority"])
            return emit(
                clean[winner_idx], "pass_cluster",
                sorted({clean[i]["source"] for i in best_cluster}),
                len(best_cluster),
            )

        # Low-confidence (tier 2/3/5/6 solo, no cluster, no authoritative). Omit.
        row.update({
            "verify_status": "fail_low_confidence",
            "candidate_sources": sorted({r["source"] for r in clean}),
        })
        return row
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def main() -> int:
    if not SLUGS_PATH.is_file():
        shim("slugs.json missing", f"python3 {REPO}/bin/logo-corpus-build-slugs.py", 60)
    if not SQUIRCLE_SH.is_file():
        shim("squircle.sh missing", f"ls {SQUIRCLE_SH}", 61)
    LEDGER.mkdir(parents=True, exist_ok=True)
    (REG / "renders").mkdir(parents=True, exist_ok=True)

    doc = json.loads(SLUGS_PATH.read_text())
    bad = json.loads(BAD.read_text())
    bad_sha = set(bad.get("sha256", []))
    bad_phash = bad.get("phash", [])
    bad_T = int(bad.get("phash_hamming_threshold", 6))

    only = set(sys.argv[1:]) if sys.argv[1:] else None
    counts: dict[str, int] = {}
    for s in doc["slugs"]:
        if not s["in_scope"]:
            continue
        if only and s["slug"] not in only:
            continue
        row = verify_slug(s["slug"], bad_sha, bad_phash, bad_T)
        (LEDGER / f"{s['slug']}.json").write_text(json.dumps(row, indent=2) + "\n")
        counts[row["verify_status"]] = counts.get(row["verify_status"], 0) + 1
    print(json.dumps(counts, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
