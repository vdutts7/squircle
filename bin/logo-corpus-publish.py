#!/usr/bin/env python3
"""Publish ledger pass_* winners into webp/<slug>.webp. Branch B — no eyeball.

Also:
  --prune-variants : delete webp/<slug>.webp whose slug matches variant SKU regex
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WEBP = REPO / "webp"
REG = REPO / "registry" / "logo-corpus"
SLUGS = REG / "slugs.json"
LEDGER = REG / "ledger"

VARIANT_REGEX = re.compile(
    r"-(coding-plan|token-plan|code-plan|step-plan)(-|$)"
    r"|-vertex(-|$)"
    r"|-cn$"
)

PASS_STATUSES = {"pass_authoritative", "pass_cluster"}


def shim(msg: str, fix: str, code: int = 70) -> None:
    sys.stderr.write(f"🔴 logo-corpus-publish: {msg} (exit {code})\n  run: {fix}\n")
    sys.exit(code)


def prune_variants() -> int:
    n = 0
    for p in WEBP.glob("*.webp"):
        if VARIANT_REGEX.search(p.stem):
            p.unlink()
            n += 1
    return n


def prune_nonpass() -> int:
    """Delete webp/<slug>.webp for in-scope slugs whose ledger status is not pass_*."""
    doc = json.loads(SLUGS.read_text())
    in_scope = {s["slug"] for s in doc["slugs"] if s["in_scope"]}
    n = 0
    for p in WEBP.glob("*.webp"):
        if p.stem not in in_scope:
            continue
        lf = LEDGER / f"{p.stem}.json"
        status = None
        if lf.is_file():
            try:
                status = json.loads(lf.read_text()).get("verify_status")
            except Exception:
                status = None
        if status not in PASS_STATUSES:
            p.unlink()
            n += 1
    return n


def publish() -> dict:
    if not SLUGS.is_file():
        shim("slugs.json missing", "python3 bin/logo-corpus-build-slugs.py", 70)
    doc = json.loads(SLUGS.read_text())
    counts = {"published": 0, "skipped_fail": 0, "missing_ledger": 0}

    for s in doc["slugs"]:
        if not s["in_scope"]:
            continue
        slug = s["slug"]
        lf = LEDGER / f"{slug}.json"
        if not lf.is_file():
            counts["missing_ledger"] += 1
            continue
        row = json.loads(lf.read_text())
        if row.get("verify_status") not in PASS_STATUSES:
            counts["skipped_fail"] += 1
            continue
        src = row.get("render_path")
        if not src or not Path(src).is_file():
            counts["missing_ledger"] += 1
            continue
        dest = WEBP / f"{slug}.webp"
        shutil.copyfile(src, dest)
        counts["published"] += 1
    return counts


def main() -> int:
    if "--prune-variants" in sys.argv:
        print(json.dumps({"pruned_variants": prune_variants()}, indent=2))
        return 0
    if "--prune-nonpass" in sys.argv:
        print(json.dumps({"pruned_nonpass": prune_nonpass()}, indent=2))
        return 0
    print(json.dumps(publish(), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
