"""core/dedup.py - merge results, dedup by normalized URL."""
from .types import norm

def merge(all_results):
    seen = {}
    for r in all_results:
        k = norm(r["url"])
        if not k or len(k) < 5: continue
        if k in seen:
            prev = seen[k]
            prev["engines"] = list(set(prev["engines"] + r["engines"]))
            prev["engine_count"] = len(prev["engines"])
            if not prev["snippet"] and r["snippet"]:
                prev["snippet"] = r["snippet"]
            if len(r["url"]) > len(prev["url"]):
                prev["url"] = r["url"]
        else:
            seen[k] = dict(r)
    out = list(seen.values())
    out.sort(key=lambda x: (-x["engine_count"], x["title"]))
    return out
