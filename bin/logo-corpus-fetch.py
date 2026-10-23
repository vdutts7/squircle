#!/usr/bin/env python3
"""Dumb cascade orchestrator.

Reads registry/logo-corpus/cascade.json; for each in-scope slug, invokes every
non-experimental tier module in order; writes raw/<slug>/<idx>-<source>.<ext>+.meta.json.
Writes raw/<slug>/FAIL.json only when every tier returned clean miss (exit 1).

Agent never routes verification back to the user.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
REG = REPO / "registry" / "logo-corpus"
SLUGS_PATH = REG / "slugs.json"
CASCADE_PATH = REG / "cascade.json"
RAW_ROOT = REG / "raw"
PY = REPO / "bin" / ".venv" / "bin" / "python3"


def shim(msg: str, fix: str, code: int = 50) -> None:
    sys.stderr.write(f"🔴 logo-corpus-fetch: {msg} (exit {code})\n  run: {fix}\n")
    sys.exit(code)


def load_universe(only: set[str] | None) -> list[str]:
    doc = json.loads(SLUGS_PATH.read_text())
    slugs = [s["slug"] for s in doc["slugs"] if s["in_scope"]]
    if only:
        slugs = [s for s in slugs if s in only]
    return slugs


def load_cascade() -> list[dict]:
    doc = json.loads(CASCADE_PATH.read_text())
    tiers = [t for t in doc["tiers"] if not t.get("experimental")]
    return tiers


def run_tier(tier: dict, slug: str) -> tuple[str, int]:
    module = REPO / tier["module"]
    out_dir = RAW_ROOT / slug
    out_dir.mkdir(parents=True, exist_ok=True)
    try:
        rc = subprocess.run(
            [str(PY), str(module), slug, "--out-dir", str(out_dir)],
            capture_output=True, text=True, timeout=180,
        ).returncode
    except subprocess.TimeoutExpired:
        rc = 124
    return tier["id"], rc


def process_slug(slug: str, tiers: list[dict]) -> dict:
    out_dir = RAW_ROOT / slug
    out_dir.mkdir(parents=True, exist_ok=True)
    # Clear prior raw artifacts (keep ledger/eyeball intact; they live elsewhere).
    for p in out_dir.iterdir():
        p.unlink()
    results = {}
    for tier in tiers:
        _, rc = run_tier(tier, slug)
        results[tier["id"]] = rc

    successes = [k for k, v in results.items() if v == 0]
    if not successes:
        (out_dir / "FAIL.json").write_text(
            json.dumps({"slug": slug, "tiers": results, "timestamp": int(time.time())}, indent=2) + "\n"
        )
    return {"slug": slug, "tiers": results, "successes": successes}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("slugs", nargs="*", help="specific slugs; else full in_scope universe")
    ap.add_argument("--parallel", type=int, default=8)
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    if not SLUGS_PATH.is_file():
        shim("slugs.json missing", f"python3 {REPO}/bin/logo-corpus-build-slugs.py", 50)
    if not CASCADE_PATH.is_file():
        shim("cascade.json missing", f"git checkout -- {CASCADE_PATH}", 50)
    if not PY.is_file():
        shim("venv python missing", f"zsh {REPO}/bin/venv.zsh", 50)

    only = set(args.slugs) if args.slugs else None
    universe = load_universe(only)
    if args.limit > 0:
        universe = universe[: args.limit]
    tiers = load_cascade()

    t0 = time.time()
    pass_count = 0
    fail_count = 0
    with ThreadPoolExecutor(max_workers=args.parallel) as ex:
        futs = {ex.submit(process_slug, slug, tiers): slug for slug in universe}
        for i, fut in enumerate(as_completed(futs), 1):
            slug = futs[fut]
            try:
                r = fut.result()
            except Exception as e:
                sys.stderr.write(f"[{slug}] exception: {e}\n")
                fail_count += 1
                continue
            n = len(r["successes"])
            if n > 0:
                pass_count += 1
            else:
                fail_count += 1
            sys.stderr.write(f"[{i}/{len(universe)}] {slug} tiers={n}/{len(tiers)} sources={','.join(r['successes']) or 'NONE'}\n")

    elapsed = time.time() - t0
    print(json.dumps({"universe": len(universe), "pass": pass_count, "fail": fail_count, "elapsed_s": round(elapsed, 1)}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
