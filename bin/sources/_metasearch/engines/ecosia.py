from ..core import result, hdrs, TIMEOUT
from bs4 import BeautifulSoup

NAME         = "ecosia"
SINGLE_PAGE  = False
EXPERIMENTAL = False

async def scrape(session, query, page):
    params = {"q": query}
    if page: params["p"] = str(page)
    r = await session.get("https://www.ecosia.org/search", params=params,
                          headers=hdrs("https://www.ecosia.org/"), timeout=TIMEOUT)
    soup = BeautifulSoup(r.text, "html.parser")
    out = []
    for a in soup.select("a.result__link"):
        par  = a.find_parent("article") or a.find_parent("div")
        snip = par.select_one(".result__description") if par else None
        out.append(result(a.get_text(strip=True), a.get("href",""),
                          snip.get_text(strip=True) if snip else "", NAME))
    return out
