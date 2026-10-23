"""core/expand.py - ZMap-style query space expansion."""

def expand_query(q: str, n: int = 6) -> list:
    """Fragment the query into overlapping variants that hit different index segments."""
    w = q.split()
    variants = [
        q,
        " ".join(w[:max(3, len(w)//2)]),
        " ".join(w[-3:]) if len(w) > 3 else q,
        f'"{w[0]} {w[1]}"' + (" " + " ".join(w[2:4]) if len(w) > 2 else "") if len(w) >= 2 else q,
        " ".join(w[i] for i in range(0, len(w), 2)),
        " ".join(reversed(w[:4])),
    ]
    seen, out = set(), []
    for v in variants:
        v = v.strip()
        if v and v not in seen:
            seen.add(v); out.append(v)
    return out[:n]
