#!/usr/bin/env python3
"""Tier 4 — models.dev clone local SVGs.

Reads providers/<slug>/logo.svg or labs/<slug>/logo.svg from the clone;
no network, no guesses. Emits Candidate idx=4 source=models_dev tier=4.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from _lib.candidate import Candidate  # noqa: E402

DEFAULT_CLONE = Path(os.environ.get("MODELS_DEV_CLONE", "/private/tmp/models.dev-dev"))


def process(slug: str, out_dir: Path, clone: Path = DEFAULT_CLONE) -> int:
    for sub in ("providers", "labs"):
        p = clone / sub / slug / "logo.svg"
        if p.is_file():
            content = p.read_bytes()
            if len(content) < 40:
                continue
            cand = Candidate(
                slug=slug, source="models_dev", tier=4,
                url=f"file://{p}", content=content, ext="svg",
                extra={"clone_subdir": sub, "clone_path": str(p)},
            )
            cand.emit(out_dir, idx=4)
            return 0
    return 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("slug")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--clone", default=str(DEFAULT_CLONE))
    args = ap.parse_args()
    rc = process(args.slug, Path(args.out_dir), Path(args.clone))
    return rc


if __name__ == "__main__":
    sys.exit(main())
