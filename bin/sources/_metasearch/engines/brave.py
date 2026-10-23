import asyncio
import urllib.parse
import urllib.request

from bs4 import BeautifulSoup

from ..core import result, hdrs, TIMEOUT

NAME = "brave"
SINGLE_PAGE = True
EXPERIMENTAL = False

_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)


def _fetch_brave_html(query: str) -> str:
    url = "https://search.brave.com/search?" + urllib.parse.urlencode(
        {"q": query, "offset": "0"}
    )
    req = urllib.request.Request(
        url,
        headers={"User-Agent": _UA, "Accept-Language": "en-US,en;q=0.9"},
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return resp.read().decode("utf-8", errors="replace")


async def scrape(session, query, page):
    if page > 0:
        return []
    for attempt in range(3):
        try:
            body = await asyncio.to_thread(_fetch_brave_html, query)
        except Exception:
            body = ""
        if not body:
            await asyncio.sleep(0.5 * (attempt + 1))
            continue
        soup = BeautifulSoup(body, "html.parser")
        out = []
        for item in soup.select('div[data-type="web"]'):
            a = item.select_one("a.l1")
            if not a:
                continue
            title_el = item.select_one(".title")
            desc_el = item.select_one(".generic-snippet .content")
            href = a.get("href", "").strip()
            title = title_el.get_text(strip=True) if title_el else a.get_text(strip=True)
            desc = desc_el.get_text(strip=True) if desc_el else ""
            if href.startswith("http"):
                out.append(result(title, href, desc, NAME))
        if out:
            return out
        await asyncio.sleep(0.5 * (attempt + 1))
    return []
