#!/usr/bin/env python3
"""Tier 6 — image search last resort.

Uses vendored metasearch to query "<slug> logo png" + "<slug> logo svg" and
picks the first URL that returns image/* with bytes > 1 KB and plausible
image header. Low-tier confidence; cross-tier phash cluster decides accept.
"""
from __future__ import annotations

import argparse
import re
import sys
import urllib.parse
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from _lib.http import get  # noqa: E402
from _lib.candidate import Candidate  # noqa: E402

IMG_URL_RE = re.compile(r"https?://[^\s'\"<>]+\.(?:png|jpg|jpeg|svg|webp|gif)", re.IGNORECASE)
IMG_HOST_SKIP = ("googleusercontent.com", "gstatic.com", "bing.com/th", "wikipedia.org/static")


def _plausible_image(data: bytes) -> str | None:
    if len(data) < 1000:
        return None
    if data[:4] == b"\x89PNG":
        return "png"
    if data[:3] == b"GIF":
        return "gif"
    if data[:2] == b"\xff\xd8":
        return "jpg"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    low = data[:200].lower()
    if b"<svg" in low or b"<?xml" in low:
        return "svg"
    return None


def _search(slug: str) -> list[str]:
    sys.path.insert(0, str(SCRIPT_DIR))
    from _metasearch.spray import spray  # noqa: E402
    out: list[str] = []
    seen: set[str] = set()
    for q in (f"{slug} logo png", f"{slug} logo svg"):
        results = spray(q, pages=1, engines=["default"])
        for r in results:
            u = r.get("url") or ""
            for m in IMG_URL_RE.finditer(u + " " + (r.get("snippet") or "")):
                hit = m.group(0)
                if any(h in hit for h in IMG_HOST_SKIP):
                    continue
                if hit in seen:
                    continue
                seen.add(hit)
                out.append(hit)
                if len(out) >= 12:
                    return out
    return out


def process(slug: str, out_dir: Path) -> int:
    urls = _search(slug)
    if not urls:
        return 1
    broke = False
    for url in urls[:6]:
        code, img = get(url)
        if code != 200 or not img:
            if code == 0:
                broke = True
            continue
        ext = _plausible_image(img)
        if not ext:
            continue
        cand = Candidate(
            slug=slug, source="bing_image", tier=6,
            url=url, content=img, ext=ext,
            extra={"query_terms": ["logo png", "logo svg"]},
        )
        cand.emit(out_dir, idx=6)
        return 0
    return 2 if broke else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("slug")
    ap.add_argument("--out-dir", required=True)
    args = ap.parse_args()
    rc = process(args.slug, Path(args.out_dir))
    return rc


if __name__ == "__main__":
    sys.exit(main())
