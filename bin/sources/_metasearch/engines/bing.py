from ..core import result, hdrs, TIMEOUT
from bs4 import BeautifulSoup

NAME         = "bing"
SINGLE_PAGE  = False
EXPERIMENTAL = False

def _url(a, cite_el):
    href = a.get("href","")
    if not cite_el: return href
    cite = cite_el.get_text(strip=True).replace(" › ","/").replace("›","/")
    if not cite.startswith("http"): cite = "https://" + cite
    return href if href.startswith("http") and len(href) > len(cite)+8 else cite

async def scrape(session, query, page):
    params = {"q": query}
    if page: params["first"] = str(page*10+1)
    r = await session.get("https://www.bing.com/search", params=params,
                          headers=hdrs("https://www.bing.com/"), timeout=TIMEOUT)
    soup = BeautifulSoup(r.text, "html.parser")
    out = []
    for res in soup.select("li.b_algo"):
        a = res.select_one("h2 a")
        if not a: continue
        snip_el = res.select_one(".b_caption p")
        out.append(result(a.get_text(strip=True), _url(a, res.select_one("cite")),
                          snip_el.get_text(strip=True) if snip_el else "", NAME))
    return out
