"""core/types.py - shared primitives used by every engine and the orchestrator."""
import re, sys, urllib.parse
from datetime import datetime, timezone

# ── Headers ───────────────────────────────────────────────
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
    "Accept-Encoding": "gzip, deflate, br",
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Site": "none",
    "Sec-Fetch-User": "?1",
    "Upgrade-Insecure-Requests": "1",
}
TIMEOUT = 20         # per HTTP call
REQ_TIMEOUT = 25     # per engine job wrapper
SLA_SECONDS = 90.0   # hard wall - 90s SLA / 10 pages default

# ── Junk filter ───────────────────────────────────────────
SKIP_HOST_BITS = (
    "facebook.com", "twitter.com", "x.com", "instagram.com",
    "privacy", "cookie", "terms", "about", "login", "sign in",
    "developer.", "visymo.com", "googletagmanager", "hotjar",
    "system1.com", "gstatic.com", "googleapis.com",
    "cdnjs.cloudflare.com", "cloudflare.com", "umami.is",
    "videoask.com", "popper.js", ".js", ".woff", ".css",
)

# ── Primitives ────────────────────────────────────────────
def log(emoji, engine, msg): print(f"{emoji} [{engine}] {msg}", file=sys.stderr)
def ts(): return datetime.now(timezone.utc).isoformat()

def result(title, url, snippet, engine):
    return {"title": title.strip(), "url": url.strip(),
            "snippet": (snippet or "").strip()[:300],
            "engines": [engine], "engine_count": 1, "scraped_at": ts()}

def norm(url):
    """Normalize URL for dedup - host + path, no query/fragment/www."""
    try:
        p = urllib.parse.urlparse(url.strip())
        if not p.netloc: return ""
        host = p.netloc.lower().replace("www.", "")
        path = re.sub(r"/+$", "", p.path or "")
        path = re.sub(r"/index\.html?$", "", path, flags=re.I)
        return f"{host}{path}"
    except Exception:
        u = url.lower().rstrip("/").replace("https://","").replace("http://","").replace("www.","")
        return u.split("?")[0].split("#")[0]

def hdrs(referer=None, **extra):
    h = dict(HEADERS)
    if referer:
        h["Referer"] = referer
        h["Sec-Fetch-Site"] = "same-origin"
    h.update(extra)
    return h

def skip_link(host, text, href):
    if not href.startswith("http"): return True
    h = urllib.parse.urlparse(href).netloc.replace("www.", "")
    if h == host.replace("www.", ""): return True
    blob = f"{text} {href}".lower()
    return any(s in blob for s in SKIP_HOST_BITS)

def snippet_from_parent(a, title):
    par = a.find_parent(["article", "li", "div", "section"])
    if not par: return ""
    return par.get_text(" ", strip=True).replace(title, "").strip()[:300]

def scrape_external(soup, host, min_len=10):
    """Generic fallback: pull all non-self external links from a soup."""
    out, seen = [], set()
    for a in soup.select("a[href^=http]"):
        href = a.get("href", "")
        title = a.get_text(" ", strip=True)
        if skip_link(host, title, href): continue
        if len(title) < min_len: continue
        key = href.split("#")[0]
        if key in seen: continue
        seen.add(key)
        out.append((title, href, snippet_from_parent(a, title)))
    return out
