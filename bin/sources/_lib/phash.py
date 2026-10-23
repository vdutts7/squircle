"""phash primitives — wraps imagehash from repo venv."""
from __future__ import annotations

import os
from pathlib import Path


def phash_file(path: str | Path) -> str | None:
    """Return hex pHash string or None on failure."""
    try:
        from PIL import Image
        import imagehash
        return str(imagehash.phash(Image.open(str(path))))
    except Exception:
        return None


def hamming(a: str, b: str) -> int:
    if not a or not b:
        return 999
    try:
        return bin(int(a, 16) ^ int(b, 16)).count("1")
    except Exception:
        return 999


def cluster(phashes: list[str], t: int = 10) -> list[list[int]]:
    """Return list of index clusters by single-link Hamming <= t."""
    n = len(phashes)
    clusters: list[list[int]] = []
    for i in range(n):
        placed = False
        for c in clusters:
            if any(hamming(phashes[i], phashes[j]) <= t for j in c):
                c.append(i)
                placed = True
                break
        if not placed:
            clusters.append([i])
    return clusters
