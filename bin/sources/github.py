#!/usr/bin/env python3
"""Tier 3 — GitHub microservice.

1. Verify-first: api.github.com/orgs/<slug> (200? use); /users/<slug> fallback.
2. metasearch spray "<slug> github" → extract github.com/<login> → verify each.
3. For verified logins: fetch github.com/<login>.png?size=512
4. Identicon reject: center 4x4 grid variance threshold.
5. Emit Candidate idx=3 source=github tier=3.

Exit 0 wrote, 1 clean miss, 2 broke.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from _lib.http import get, get_json  # noqa: E402
from _lib.candidate import Candidate  # noqa: E402
from wikipedia import normalize, levenshtein  # noqa: E402

LOGIN_RE = re.compile(r"github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})(?:/|$|\?|#)")
BAD_PATHS = {
    "orgs", "users", "topics", "trending", "features", "about",
    "pricing", "login", "join", "search", "settings", "enterprise",
    "security", "readme", "signup", "sponsors", "marketplace",
    "collections", "events", "mobile", "customer-stories",
    "codespaces", "copilot", "pulls", "issues", "notifications",
}


def verify_login(login: str) -> str | None:
    for kind in ("orgs", "users"):
        code, data = get_json(f"https://api.github.com/{kind}/{login}")
        if code == 200 and isinstance(data, dict) and data.get("login"):
            return data["login"]
    return None


def discover_logins(slug: str) -> list[str]:
    sys.path.insert(0, str(SCRIPT_DIR))
    from _metasearch.spray import spray  # noqa: E402
    results = spray(f"{slug} github", pages=1, engines=["default"])
    logins: list[str] = []
    seen: set[str] = set()
    for r in results:
        for m in LOGIN_RE.finditer(r.get("url", "")):
            l = m.group(1)
            ll = l.lower()
            if ll in BAD_PATHS:
                continue
            if ll in seen:
                continue
            seen.add(ll)
            logins.append(l)
    return logins


def is_identicon(img: bytes) -> bool:
    """GitHub identicons are generated 5x5 colored-cell patterns with huge flat regions.
    Our heuristic: use PIL to downscale to 8x8, measure variance per-channel; identicons
    show stripe variance (one dominant hue). Low discriminator — only reject obvious ones.
    """
    try:
        from PIL import Image
        import io
        im = Image.open(io.BytesIO(img)).convert("RGB").resize((8, 8))
        px = list(im.getdata())
        rs = [p[0] for p in px]; gs = [p[1] for p in px]; bs = [p[2] for p in px]
        def var(xs):
            m = sum(xs) / len(xs)
            return sum((x - m) ** 2 for x in xs) / len(xs)
        total_var = var(rs) + var(gs) + var(bs)
        # Real logos vary a lot (>2000); identicons on white or single-hue bg vary little.
        return total_var < 400
    except Exception:
        return False


def process(slug: str, out_dir: Path) -> int:
    slug_norm = normalize(slug)

    verified: list[str] = []
    direct = verify_login(slug)
    if direct:
        verified.append(direct)

    for login in discover_logins(slug):
        v = verify_login(login)
        if v and v not in verified:
            verified.append(v)
        if len(verified) >= 5:
            break

    if not verified:
        return 1

    # Rank verified logins by Levenshtein to slug (stable tiebreak by discovery order).
    pos = {l: i for i, l in enumerate(verified)}
    verified.sort(key=lambda l: (levenshtein(slug_norm, normalize(l)), pos[l]))

    broke = False
    for login in verified[:3]:
        url = f"https://github.com/{login}.png?size=512"
        code, img = get(url)
        if code != 200 or not img:
            broke = True
            continue
        if len(img) < 500:
            continue
        if is_identicon(img):
            continue
        ext = "png" if img[:4] == b"\x89PNG" else "jpg"
        cand = Candidate(
            slug=slug, source="github", tier=3,
            url=url, content=img, ext=ext,
            extra={"login": login, "verified": verified},
        )
        cand.emit(out_dir, idx=3)
        return 0
    return 2 if broke else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("slug")
    ap.add_argument("--out-dir", required=True)
    args = ap.parse_args()
    rc = process(args.slug, Path(args.out_dir))
    if rc == 2:
        print(f"🔴 github: broke on {args.slug} (exit 2)\n  run: python3 bin/sources/github.py {args.slug} --out-dir {args.out_dir}", file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main())
