#!/usr/bin/env python3
"""Tier 2 — Twitter / X microservice.

1. metasearch spray "<slug> site:twitter.com OR site:x.com"
2. Regex handles from result URLs
3. Rank by Levenshtein(slug_norm, handle_norm) ascending
4. For top 3 ranked: fetch https://unavatar.io/twitter/<handle> (follows 302)
5. Reject < 300 bytes or default-egg sha256
6. Emit Candidate idx=2 source=twitter tier=2

Exit 0 wrote, 1 clean miss, 2 broke.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from _lib.http import get  # noqa: E402
from _lib.candidate import Candidate  # noqa: E402
from wikipedia import normalize, levenshtein  # noqa: E402

HANDLE_RE = re.compile(r"(?:twitter|x)\.com/([A-Za-z0-9_]{1,15})(?:/|$|\?)")
BAD_PATHS = {
    "intent", "share", "home", "login", "signup", "search",
    "settings", "about", "privacy", "tos", "i", "notifications",
    "messages", "explore", "compose", "download",
}

# Default-egg + abstract-silhouette sha256 patterns pinned over time
# (populated as encountered; initial seed empty — update known-bad-anchors.json)
EGG_HASHES: set[str] = set()


def find_handles(slug: str) -> list[str]:
    sys.path.insert(0, str(SCRIPT_DIR))
    from _metasearch.spray import spray  # noqa: E402
    # Plain "<slug> twitter" yields more hits than site: operators across
    # vendored engines (ddg_lite/bing/ecosia inconsistent with OR syntax).
    results = spray(f"{slug} twitter", pages=1, engines=["default"])
    handles: list[str] = []
    seen: set[str] = set()
    for r in results:
        for m in HANDLE_RE.finditer(r.get("url", "")):
            h = m.group(1)
            lh = h.lower()
            if lh in BAD_PATHS:
                continue
            if lh in seen:
                continue
            seen.add(lh)
            handles.append(h)
    return handles


def rank_handles(slug: str, handles: list[str]) -> list[str]:
    slug_norm = normalize(slug)
    return sorted(handles, key=lambda h: (levenshtein(slug_norm, normalize(h)), handles.index(h)))


def process(slug: str, out_dir: Path) -> int:
    handles = find_handles(slug)
    if not handles:
        return 1
    ranked = rank_handles(slug, handles)[:3]
    broke = False
    for handle in ranked:
        url = f"https://unavatar.io/twitter/{handle}"
        code, img = get(url)
        if code != 200 or not img:
            broke = True
            continue
        if len(img) < 300:
            continue
        import hashlib
        sha = hashlib.sha256(img).hexdigest()
        if sha in EGG_HASHES:
            continue
        ext = "jpg"
        if img[:4] == b"\x89PNG":
            ext = "png"
        elif img[:4] == b"GIF8":
            ext = "gif"
        elif img.startswith(b"<?xml") or img.startswith(b"<svg"):
            ext = "svg"
        cand = Candidate(
            slug=slug, source="twitter", tier=2,
            url=url, content=img, ext=ext,
            extra={"handle": handle, "handles_considered": ranked},
        )
        cand.emit(out_dir, idx=2)
        return 0
    return 2 if broke else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("slug")
    ap.add_argument("--out-dir", required=True)
    args = ap.parse_args()
    out_dir = Path(args.out_dir)
    rc = process(args.slug, out_dir)
    if rc == 2:
        print(f"🔴 twitter: broke on {args.slug} (exit 2)\n  run: python3 bin/sources/twitter.py {args.slug} --out-dir {out_dir}", file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main())
