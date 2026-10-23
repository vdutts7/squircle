#!/usr/bin/env python3
"""Tier 5 — Google s2 favicon + apple-touch-icon.

Needs a hostname; derives from models.dev-dev provider.toml `homepage` field
or SQUIRCLE_FAVICON_HOST env var. Skips (clean miss) if no host available.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import urllib.parse
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from _lib.http import get  # noqa: E402
from _lib.candidate import Candidate  # noqa: E402

DEFAULT_CLONE = Path(os.environ.get("MODELS_DEV_CLONE", "/private/tmp/models.dev-dev"))


def host_from_clone(slug: str, clone: Path) -> str | None:
    for sub in ("providers", "labs"):
        p = clone / sub / slug / "provider.toml"
        if not p.is_file():
            continue
        text = p.read_text(errors="replace")
        for key in ("homepage", "doc", "api", "docs"):
            m = re.search(rf'^\s*{key}\s*=\s*"([^"]+)"', text, re.M)
            if m:
                u = m.group(1)
                try:
                    netloc = urllib.parse.urlparse(u).netloc
                    if netloc:
                        netloc = netloc.lower()
                        # Iteratively strip subdomain prefixes until stable.
                        pfxs = ("www.", "docs.", "doc.", "api.", "platform.",
                                "developer.", "developers.", "console.",
                                "integrate.", "ai.", "build.")
                        changed = True
                        while changed:
                            changed = False
                            for pfx in pfxs:
                                if netloc.startswith(pfx) and netloc.count(".") >= 2:
                                    netloc = netloc[len(pfx):]
                                    changed = True
                                    break
                        return netloc
                except Exception:
                    pass
    return None


def process(slug: str, out_dir: Path, host: str | None = None) -> int:
    host = host or host_from_clone(slug, DEFAULT_CLONE)
    if not host:
        return 1

    tried_any = False
    broke = False
    attempts = [
        (f"https://www.google.com/s2/favicons?domain={host}&sz=256", "google_s2_256"),
        (f"https://{host}/apple-touch-icon.png", "apple_touch"),
        (f"https://{host}/apple-touch-icon-precomposed.png", "apple_touch_precomp"),
    ]
    for url, kind in attempts:
        tried_any = True
        code, img = get(url)
        if code != 200 or not img:
            if code == 0:
                broke = True
            continue
        if len(img) < 200:
            continue
        ext = "png" if img[:4] == b"\x89PNG" else "ico"
        cand = Candidate(
            slug=slug, source="favicon", tier=5,
            url=url, content=img, ext=ext,
            extra={"host": host, "kind": kind},
        )
        cand.emit(out_dir, idx=5)
        return 0
    return 2 if broke else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("slug")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--host", default=None)
    args = ap.parse_args()
    rc = process(args.slug, Path(args.out_dir), args.host)
    return rc


if __name__ == "__main__":
    sys.exit(main())
