from ..core import result, hdrs, HEADERS, TIMEOUT
from bs4 import BeautifulSoup

NAME         = "ddg_lite"
SINGLE_PAGE  = False
EXPERIMENTAL = False

async def scrape(session, query, page):
    data = {"q": query}
    if page:
        data.update({"s": str(page*11), "nextParams":"", "v":"l", "o":"json", "dc": str(page*11+1)})
    r = await session.post("https://lite.duckduckgo.com/lite/", data=data, headers=HEADERS, timeout=TIMEOUT)
    soup = BeautifulSoup(r.text, "html.parser")
    links = soup.select("a.result-link")
    snippets = soup.select("td.result-snippet")
    out = []
    for i, a in enumerate(links):
        snip = snippets[i].get_text(strip=True) if i < len(snippets) else ""
        out.append(result(a.get_text(strip=True), a.get("href",""), snip, NAME))
    return out
