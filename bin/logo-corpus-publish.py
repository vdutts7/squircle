#!/usr/bin/env python3
"""Publish verified + eyeball-approved renders into webp/<slug>.webp.

Rules:
  --prune-variants  — delete any webp/<slug>.webp whose <slug> matches the
                      variant regex. Does NOT delete slugs outside the universe
                      (pre-existing non-models.dev icons stay untouched).
  default           — for every slug with ledger pass AND eyeball approved,
                      copy ledger.render_path to webp/<slug>.webp (overwrite).
                      Slugs without approval are skipped silently; they fail
                      the write-law gate until approved.
"""
from __future__ import annotations

import json
import re
import shutil
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WEBP = REPO / "webp"
REG = REPO / "registry" / "logo-corpus"
SLUGS = REG / "slugs.json"
LEDGER = REG / "ledger"
EYE = REG / "eyeball.json"

VARIANT_REGEX = re.compile(
    r"-(coding-plan|token-plan|code-plan)(-|$)"
    r"|-vertex(-|$)"
    r"|-cn$"
)


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


def publish() -> dict:
    if not SLUGS.is_file():
        shim("slugs.json missing", "python3 bin/logo-corpus-build-slugs.py", 70)
    doc = json.loads(SLUGS.read_text())
    eye = json.loads(EYE.read_text()).get("slugs", {})

    counts = {"published": 0, "skipped_no_pass": 0, "skipped_no_approval": 0, "missing_ledger": 0}

    for s in doc["slugs"]:
        if not s["in_scope"]:
            continue
        slug = s["slug"]
        lf = LEDGER / f"{slug}.json"
        if not lf.is_file():
            counts["missing_ledger"] += 1
            continue
        row = json.loads(lf.read_text())
        if row.get("verify_status") != "pass":
            counts["skipped_no_pass"] += 1
            continue
        if eye.get(slug, {}).get("human_verdict") != "approved":
            counts["skipped_no_approval"] += 1
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
        pruned = prune_variants()
        print(json.dumps({"pruned_variants": pruned}, indent=2))
        return 0
    print(json.dumps(publish(), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
