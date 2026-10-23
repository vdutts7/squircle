#!/usr/bin/env python3
"""Verify every in-scope slug: render each raw/<slug>/* through squircle, phash-cluster,
reject known-bad anchors, write ledger/<slug>.json.

verify_status:
  pass                — cluster_members >= 2 under T, or only one source but it is
                        provider_svg (highest-priority declared source)
  fail_no_source      — raw/<slug>/FAIL.json present or no artifacts
  fail_no_cluster     — multiple sources all disagree
  fail_known_bad      — any winner sha256 or phash hits known-bad-anchors.json
"""
from __future__ import annotations

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
BIN = REPO / "bin"
REG = REPO / "registry" / "logo-corpus"
SLUGS = REG / "slugs.json"
RAW = REG / "raw"
LEDGER = REG / "ledger"
BAD = REG / "known-bad-anchors.json"

SQUIRCLE_SH = BIN / "squircle.sh"
PHASH_PICK = BIN / "phash-pick.zsh"
CLUSTER_T = 8


def shim(msg: str, fix: str, code: int = 60) -> None:
    sys.stderr.write(f"🔴 logo-corpus-verify: {msg} (exit {code})\n  run: {fix}\n")
    sys.exit(code)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def phash_hex(path: Path) -> str | None:
    """Prefer phash-pick helper, fall back to python-imagehash if available."""
    try:
        res = subprocess.run(
            ["zsh", str(PHASH_PICK), "--hash", str(path)],
            capture_output=True, text=True, timeout=30,
        )
        if res.returncode == 0 and res.stdout.strip():
            return res.stdout.strip().split()[0]
    except Exception:
        pass
    try:
        from PIL import Image  # type: ignore
        import imagehash       # type: ignore
        return str(imagehash.phash(Image.open(path)))
    except Exception:
        return None


def hamming(a: str, b: str) -> int:
    try:
        return bin(int(a, 16) ^ int(b, 16)).count("1")
    except Exception:
        return 999


def render(raw_file: Path, out: Path) -> bool:
    env = os.environ.copy()
    env["SQUIRCLE_AUTO_PLAN"] = "1"
    env["SQUIRCLE_POSTCHECK"] = "1"
    try:
        res = subprocess.run(
            [str(SQUIRCLE_SH), "-q", str(raw_file), "--out", str(out)],
            capture_output=True, text=True, timeout=60, env=env,
        )
        return res.returncode == 0 and out.is_file() and out.stat().st_size > 0
    except Exception as e:
        sys.stderr.write(f"    render {raw_file}: {e}\n")
        return False


PRIORITY = {
    "models_dev_provider_svg": 5,
    "models_dev_lab_svg": 4,
    "declared_github": 3,
    "declared_twitter": 2,
    "declared_homepage_favicon": 1,
}


def pick_winner(renders: list[dict]) -> tuple[dict | None, list[list[int]]]:
    """Cluster by phash Hamming <= CLUSTER_T, choose cluster containing highest-priority source."""
    n = len(renders)
    if n == 0:
        return None, []
    clusters: list[list[int]] = []
    for i in range(n):
        placed = False
        for c in clusters:
            if any(hamming(renders[i]["phash"], renders[j]["phash"]) <= CLUSTER_T for j in c):
                c.append(i)
                placed = True
                break
        if not placed:
            clusters.append([i])
    best_cluster = max(
        clusters,
        key=lambda c: (max(PRIORITY.get(renders[i]["kind"], 0) for i in c), len(c)),
    )
    winner_idx = max(best_cluster, key=lambda i: PRIORITY.get(renders[i]["kind"], 0))
    return renders[winner_idx], clusters


def verify_slug(slug: str, bad_sha: set, bad_phash: list, bad_T: int) -> dict:
    d = RAW / slug
    row = {"slug": slug, "verify_status": "fail_no_source", "timestamp": int(time.time())}
    if not d.is_dir():
        return row
    if (d / "FAIL.json").is_file():
        return row

    artifacts = sorted(p for p in d.iterdir() if p.is_file() and p.name != "FAIL.json")
    if not artifacts:
        return row

    tmp_dir = Path(tempfile.mkdtemp(prefix=f"lcv-{slug}-"))
    renders: list[dict] = []
    try:
        for a in artifacts:
            m = re.match(r"^\d+-([a-z_]+)\.", a.name)
            kind = m.group(1) if m else "unknown"
            out = tmp_dir / f"{a.stem}.webp"
            if not render(a, out):
                continue
            ph = phash_hex(out)
            if ph is None:
                continue
            renders.append({
                "kind": kind,
                "src_path": str(a),
                "src_sha256": sha256(a),
                "render_path": str(out),
                "render_sha256": sha256(out),
                "phash": ph,
            })

        if not renders:
            row["verify_status"] = "fail_no_source"
            return row

        winner, clusters = pick_winner(renders)
        if winner is None:
            row["verify_status"] = "fail_no_cluster"
            return row

        if winner["src_sha256"] in bad_sha or winner["render_sha256"] in bad_sha:
            row["verify_status"] = "fail_known_bad"
            row["winner_source"] = winner["kind"]
            row["winner_sha256"] = winner["render_sha256"]
            return row
        for bp in bad_phash:
            if hamming(winner["phash"], bp) <= bad_T:
                row["verify_status"] = "fail_known_bad"
                row["winner_source"] = winner["kind"]
                row["winner_sha256"] = winner["render_sha256"]
                return row

        if len(renders) == 1 and winner["kind"] != "models_dev_provider_svg":
            row["verify_status"] = "fail_no_cluster"
        elif len(clusters) > 1 and len([c for c in clusters if len(c) >= 2]) == 0 and len(renders) > 1:
            row["verify_status"] = "fail_no_cluster"
        else:
            row["verify_status"] = "pass"

        row["winner_source"] = winner["kind"]
        row["winner_sha256"] = winner["render_sha256"]
        row["output_phash"] = winner["phash"]
        row["render_path"] = winner["render_path"]
        row["cluster_sizes"] = [len(c) for c in clusters]
        return row
    finally:
        try:
            shutil.rmtree(tmp_dir, ignore_errors=True)
        except Exception:
            pass


def main() -> int:
    if not SLUGS.is_file():
        shim("slugs.json missing", f"python3 {BIN}/logo-corpus-build-slugs.py", 60)
    if not SQUIRCLE_SH.is_file():
        shim("squircle.sh missing", f"ls {SQUIRCLE_SH}", 61)
    doc = json.loads(SLUGS.read_text())
    bad = json.loads(BAD.read_text())
    bad_sha = set(bad.get("sha256", []))
    bad_phash = bad.get("phash", [])
    bad_T = int(bad.get("phash_hamming_threshold", 6))

    LEDGER.mkdir(parents=True, exist_ok=True)

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
