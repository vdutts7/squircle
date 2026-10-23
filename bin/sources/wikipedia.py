#!/usr/bin/env python3
"""Tier 1 — Wikipedia / Wikimedia Commons microservice.

Order:
  1. MediaWiki OpenSearch API for "<slug> (company)"; take top 3 article URLs.
  2. For each: fetch article HTML, parse og:image (or infobox logo).
  3. Levenshtein guard: article title vs slug (normalized) <= 3; else skip.
  4. Fallback: metasearch spray "<slug> site:wikipedia.org" and repeat 2+3.
  5. Download winner image; emit Candidate idx=01 source=wikipedia tier=1.

Exit codes:
  0 — >=1 candidate written
  1 — clean miss (no article passed Levenshtein / og:image / known-bad)
  2 — source broke (network, parse error on all paths)
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.parse
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from _lib.http import get, get_json  # noqa: E402
from _lib.candidate import Candidate  # noqa: E402

WIKI_LOGO_BLACKLIST_URL_FRAGMENTS = (
    "/static/images/icons/wikipedia.png",
    "/static/images/mobile/copyright/wikipedia-wordmark-en.svg",
    "/static/images/project-logos/enwiki.png",
    "File_not_found",
)


def normalize(s: str) -> str:
    return re.sub(r"[^a-z0-9]", "", s.lower())


def levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, cb in enumerate(b, 1):
            cost = 0 if ca == cb else 1
            cur[j] = min(cur[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost)
        prev = cur
    return prev[-1]


def opensearch(query: str, limit: int = 3) -> list[tuple[str, str]]:
    url = (
        "https://en.wikipedia.org/w/api.php?"
        + urllib.parse.urlencode(
            {"action": "opensearch", "search": query, "limit": str(limit),
             "namespace": "0", "format": "json"}
        )
    )
    code, data = get_json(url)
    if code != 200 or not isinstance(data, list) or len(data) < 4:
        return []
    titles, urls = data[1], data[3]
    return list(zip(titles, urls))


def _file_url(file_name: str) -> str | None:
    """Resolve File:<name> → direct image URL via MediaWiki imageinfo."""
    title = file_name.strip().replace(" ", "_")
    if not title.lower().startswith("file:"):
        title = "File:" + title
    url = (
        "https://en.wikipedia.org/w/api.php?"
        + urllib.parse.urlencode(
            {"action": "query", "titles": title, "prop": "imageinfo",
             "iiprop": "url", "format": "json"}
        )
    )
    code, data = get_json(url)
    if code != 200 or not isinstance(data, dict):
        return None
    pages = (data.get("query") or {}).get("pages") or {}
    for _, page in pages.items():
        ii = page.get("imageinfo") or []
        if ii and ii[0].get("url"):
            u = ii[0]["url"]
            if not any(frag in u for frag in WIKI_LOGO_BLACKLIST_URL_FRAGMENTS):
                return u
    return None


def _wikitext_logo_file(page_title: str) -> str | None:
    """Fetch article wikitext, parse infobox for |logo= or |image= field."""
    title = page_title.replace(" ", "_")
    url = (
        "https://en.wikipedia.org/w/api.php?"
        + urllib.parse.urlencode(
            {"action": "parse", "page": title, "prop": "wikitext",
             "format": "json", "formatversion": "2"}
        )
    )
    code, data = get_json(url)
    if code != 200 or not isinstance(data, dict):
        return None
    text = ((data.get("parse") or {}).get("wikitext") or "")
    if not isinstance(text, str) or not text:
        return None
    # Prefer |logo = ... ; fallback |image = ... (first match).
    for key in ("logo", "logo_caption", "image"):
        m = re.search(
            rf"\|\s*{key}\s*=\s*(?:\[\[\s*File\s*:\s*)?([^\|\]\n<]+?\.(?:svg|png|jpg|jpeg|webp|gif))",
            text, re.IGNORECASE,
        )
        if m:
            name = m.group(1).strip()
            if name:
                return name
    return None


def extract_logo_url(article_html: bytes, base: str, page_title: str | None = None) -> str | None:
    # 1) Wikitext infobox |logo= — authoritative when present.
    if page_title:
        f = _wikitext_logo_file(page_title)
        if f:
            u = _file_url(f)
            if u:
                return u
    text = article_html.decode("utf-8", errors="replace")
    # 2) Infobox HTML: img whose alt contains 'logo'
    for m in re.finditer(r'<img\s+[^>]*alt="([^"]*)"[^>]*src="([^"]+)"', text):
        alt, src = m.group(1), m.group(2)
        if "logo" in alt.lower():
            u = src
            if u.startswith("//"):
                u = "https:" + u
            if not any(frag in u for frag in WIKI_LOGO_BLACKLIST_URL_FRAGMENTS):
                return _upgrade_to_full_res(u)
    # 3) Last-resort og:image (frequently wrong — building photos, screenshots).
    m = re.search(r'<meta\s+property="og:image"\s+content="([^"]+)"', text)
    if m:
        candidate = m.group(1)
        if not any(frag in candidate for frag in WIKI_LOGO_BLACKLIST_URL_FRAGMENTS):
            return _upgrade_to_full_res(candidate)
    return None


def _upgrade_to_full_res(url: str) -> str:
    """WP thumb URL → full-res by stripping /thumb/ segment and the trailing size prefix."""
    if "/thumb/" in url:
        parts = url.split("/thumb/", 1)
        rest = parts[1]
        # rest: a/ab/File.svg/1280px-File.svg → want: a/ab/File.svg
        segs = rest.split("/")
        if len(segs) >= 4:
            return parts[0] + "/" + "/".join(segs[:3])
    return url


def metasearch_fallback(slug: str) -> list[str]:
    """Return candidate WP article URLs via metasearch spray."""
    sys.path.insert(0, str(SCRIPT_DIR))
    from _metasearch.spray import spray  # noqa: E402
    results = spray(f"{slug} site:wikipedia.org", pages=1, engines=["default"])
    urls = []
    for r in results:
        u = r.get("url", "")
        if "wikipedia.org/wiki/" in u and ":" not in u.split("/wiki/", 1)[1][:40]:
            urls.append(u)
        if len(urls) >= 3:
            break
    return urls


def process(slug: str, out_dir: Path) -> int:
    slug_norm = normalize(slug)

    pairs: list[tuple[str, str]] = []
    seen: set[str] = set()
    for q in (slug, f"{slug} (company)", f"{slug} AI", f"{slug} inc"):
        for t, u in opensearch(q, limit=3):
            if u not in seen:
                seen.add(u)
                pairs.append((t, u))

    fallback_urls = []
    if not any(levenshtein(slug_norm, normalize(t)) <= 3 for t, _ in pairs):
        fallback_urls = metasearch_fallback(slug)

    def iter_candidates():
        for title, url in pairs:
            yield title, url
        for url in fallback_urls:
            title = urllib.parse.unquote(url.rsplit("/wiki/", 1)[-1]).replace("_", " ")
            yield title, url

    broke = False
    for title, article_url in iter_candidates():
        title_norm = normalize(title)
        if levenshtein(slug_norm, title_norm) > 3:
            continue
        code, html = get(article_url)
        if code != 200 or not html:
            broke = True
            continue
        logo_url = extract_logo_url(html, article_url, page_title=title)
        if not logo_url:
            continue
        if logo_url.startswith("//"):
            logo_url = "https:" + logo_url
        code2, img = get(logo_url)
        if code2 != 200 or not img:
            broke = True
            continue
        ext = Path(urllib.parse.urlparse(logo_url).path).suffix.lower().lstrip(".") or "png"
        if ext not in ("svg", "png", "jpg", "jpeg", "webp", "gif"):
            ext = "png"
        cand = Candidate(
            slug=slug, source="wikipedia", tier=1,
            url=logo_url, content=img, ext=ext,
            extra={"article_url": article_url, "article_title": title},
        )
        cand.emit(out_dir, idx=1)
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
        print(f"🔴 wikipedia: broke on {args.slug} (exit 2)\n  run: python3 {Path(__file__).name} {args.slug} --out-dir {out_dir}", file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main())
