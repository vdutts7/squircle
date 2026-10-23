"""Minimal HTTP get for logo-corpus sources. Uses stdlib urllib + optional curl_cffi."""
from __future__ import annotations

import io
import sys
import urllib.request
import urllib.error
from pathlib import Path

UA = "squircle-logo-corpus/1 (+https://github.com/vdutts7)"
DEFAULT_TIMEOUT = 15
MAX_BYTES = 5 * 1024 * 1024  # 5 MB cap


def get(url: str, timeout: int = DEFAULT_TIMEOUT, headers: dict | None = None) -> tuple[int, bytes]:
    """Return (status, body_bytes). Follows redirects. 0 status on exception."""
    h = {"User-Agent": UA, "Accept": "*/*"}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            buf = io.BytesIO()
            total = 0
            while True:
                chunk = r.read(65536)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_BYTES:
                    return 413, buf.getvalue()
                buf.write(chunk)
            return r.getcode(), buf.getvalue()
    except urllib.error.HTTPError as e:
        return e.code, b""
    except Exception as e:
        print(f"[http] {url}: {e}", file=sys.stderr)
        return 0, b""


def get_json(url: str, **kw) -> tuple[int, object]:
    import json as _json
    code, body = get(url, **kw)
    if code != 200 or not body:
        return code, None
    try:
        return code, _json.loads(body.decode("utf-8", errors="replace"))
    except Exception:
        return code, None


def write_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
