#!/usr/bin/env python3
"""Fetch sources per slug per sources.json#default_order.

Legal source kinds (sources.json#kinds_enum):
  models_dev_provider_svg  — <clone>/providers/<id>/logo.svg
  models_dev_lab_svg       — <clone>/labs/<id>/logo.svg
  declared_github          — overrides.json slugs[slug].github.login (+ verified_at)
  declared_twitter         — overrides.json slugs[slug].twitter.handle (+ verified_at)
  declared_homepage_favicon— overrides.json slugs[slug].homepage (+ verified_at)

Agent is forbidden from adding any kind outside the enum. No slug+ai, no slug-ai,
no bing scrape, no --domain, no "guess". If a declared source is missing, the slug
gets a FAIL.json row — publish.py will keep that slug's existing webp (if any) untouched.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
REG = REPO / "registry" / "logo-corpus"
SLUGS = REG / "slugs.json"
SOURCES = REG / "sources.json"
OVERRIDES = REG / "overrides.json"
RAW = REG / "raw"

TIMEOUT = 15
UA = "squircle-logo-corpus/1 (local; no-tracking)"


def shim(msg: str, fix: str, code: int = 50) -> None:
    sys.stderr.write(f"🔴 logo-corpus-fetch: {msg} (exit {code})\n  run: {fix}\n")
    sys.exit(code)


def http_get(url: str, dest: Path) -> bool:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            data = r.read()
        if not data:
            return False
        dest.write_bytes(data)
        return True
    except Exception as e:
        sys.stderr.write(f"    http {url}: {e}\n")
        return False


def copy_file(src: Path, dest: Path) -> bool:
    try:
        shutil.copyfile(src, dest)
        return True
    except Exception as e:
        sys.stderr.write(f"    copy {src}: {e}\n")
        return False


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch_slug(slug: str, order: list, overrides: dict, clone: Path) -> dict:
    d = RAW / slug
    d.mkdir(parents=True, exist_ok=True)
    for old in d.iterdir():
        old.unlink()

    attempts = []
    for idx, kind in enumerate(order, start=1):
        ext, src_desc, ok = None, None, False
        tmp_dest: Path | None = None

        if kind == "models_dev_provider_svg":
            src = clone / "providers" / slug / "logo.svg"
            if src.is_file():
                ext = "svg"
                tmp_dest = d / f"{idx:02d}-{kind}.{ext}"
                ok = copy_file(src, tmp_dest)
                src_desc = str(src)

        elif kind == "models_dev_lab_svg":
            src = clone / "labs" / slug / "logo.svg"
            if src.is_file():
                ext = "svg"
                tmp_dest = d / f"{idx:02d}-{kind}.{ext}"
                ok = copy_file(src, tmp_dest)
                src_desc = str(src)

        elif kind == "declared_github":
            o = overrides.get(slug, {}).get("github", {})
            if o.get("login") and o.get("verified_at"):
                url = f"https://github.com/{o['login']}.png?size=512"
                ext = "png"
                tmp_dest = d / f"{idx:02d}-{kind}.{ext}"
                ok = http_get(url, tmp_dest)
                src_desc = url

        elif kind == "declared_twitter":
            o = overrides.get(slug, {}).get("twitter", {})
            if o.get("handle") and o.get("verified_at"):
                url = f"https://unavatar.io/twitter/{o['handle']}"
                ext = "png"
                tmp_dest = d / f"{idx:02d}-{kind}.{ext}"
                ok = http_get(url, tmp_dest)
                src_desc = url

        elif kind == "declared_homepage_favicon":
            o = overrides.get(slug, {}).get("homepage", {})
            if o.get("url") and o.get("verified_at"):
                host = re.sub(r"^https?://", "", o["url"]).split("/")[0]
                url = f"https://{host}/apple-touch-icon.png"
                ext = "png"
                tmp_dest = d / f"{idx:02d}-{kind}.{ext}"
                ok = http_get(url, tmp_dest)
                src_desc = url

        if ok and tmp_dest and tmp_dest.exists():
            attempts.append({
                "kind": kind,
                "src": src_desc,
                "artifact": str(tmp_dest),
                "sha256": sha256(tmp_dest),
                "bytes": tmp_dest.stat().st_size,
            })
        else:
            if tmp_dest and tmp_dest.exists():
                tmp_dest.unlink()
            attempts.append({"kind": kind, "src": src_desc, "artifact": None, "sha256": None, "bytes": 0})

    successes = [a for a in attempts if a["artifact"]]
    if not successes:
        (d / "FAIL.json").write_text(json.dumps({
            "slug": slug,
            "attempts": attempts,
            "timestamp": int(time.time()),
        }, indent=2) + "\n")
    return {"slug": slug, "attempts": attempts, "successes": len(successes)}


def main() -> int:
    if not SLUGS.is_file():
        shim("slugs.json missing", f"python3 {REPO}/bin/logo-corpus-build-slugs.py", 50)
    doc = json.loads(SLUGS.read_text())
    sources = json.loads(SOURCES.read_text())
    overrides = json.loads(OVERRIDES.read_text()).get("slugs", {})
    clone = Path(sources["paths"]["models_dev_clone"])
    if not clone.is_dir():
        shim("models.dev clone missing", f"git clone https://github.com/sst/models.dev {clone}", 51)
    order = sources["default_order"]

    only = set(sys.argv[1:]) if sys.argv[1:] else None

    processed = 0
    fully_failed = 0
    for s in doc["slugs"]:
        if not s["in_scope"]:
            continue
        if only and s["slug"] not in only:
            continue
        r = fetch_slug(s["slug"], order, overrides, clone)
        processed += 1
        if r["successes"] == 0:
            fully_failed += 1
            sys.stderr.write(f"    FAIL {s['slug']} — no legal source produced an artifact\n")

    print(json.dumps({"processed": processed, "fully_failed": fully_failed}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
