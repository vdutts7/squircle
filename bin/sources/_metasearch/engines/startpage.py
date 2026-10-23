import urllib.parse

from bs4 import BeautifulSoup

from ..core import result, hdrs, TIMEOUT

NAME = "startpage"
SINGLE_PAGE = False
EXPERIMENTAL = False


def _unwrap_startpage_url(href: str) -> str:
    if "/sp/search/" in href or "startpage.com" in href:
        parsed = urllib.parse.urlparse(href)
        qs = urllib.parse.parse_qs(parsed.query)
        if "t" in qs:
            return urllib.parse.unquote(qs["t"][0])
        if "u" in qs:
            return urllib.parse.unquote(qs["u"][0])
    return href


async def scrape(session, query, page):
    params = {"q": query, "page": str(page + 1)}
    r = await session.get(
        "https://www.startpage.com/search",
        params=params,
        headers=hdrs("https://www.startpage.com/"),
        timeout=TIMEOUT,
    )
    if r.status_code != 200:
        return []
    soup = BeautifulSoup(r.text, "html.parser")
    out = []
    for item in soup.select("div.result"):
        a = item.select_one("a.result-title")
        if not a:
            continue
        desc_el = item.select_one("p.description")
        href = _unwrap_startpage_url(a.get("href", "").strip())
        if not href.startswith("http"):
            continue
        out.append(result(
            a.get_text(strip=True),
            href,
            desc_el.get_text(strip=True) if desc_el else "",
            NAME,
        ))
    return out
