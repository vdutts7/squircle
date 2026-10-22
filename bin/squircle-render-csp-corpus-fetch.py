#!/usr/bin/env python3
"""Fetch N unique raster logos from the public internet into render-CSP corpus."""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

SKIP_DOMAINS = frozenset(
    {
        "google.com",
        "gstatic.com",
        "googleapis.com",
        "cloudflare.com",
        "amazonaws.com",
        "akamai.net",
        "facebook.com",
        "fbcdn.net",
        "microsoft.com",
        "apple.com",
        "icloud.com",
        "doubleclick.net",
        "googlesyndication.com",
        "googleusercontent.com",
        "youtube.com",
        "ytimg.com",
        "twitter.com",
        "twimg.com",
        "instagram.com",
        "linkedin.com",
        "amazon.com",
        "windows.net",
        "azure.com",
        "office.com",
        "live.com",
        "office365.com",
        "github.com",
        "githubusercontent.com",
    }
)

MAGICK = Path("/opt/homebrew/bin/magick")
if not MAGICK.is_file():
    MAGICK = Path("/usr/local/bin/magick")

UA = "squircle-corpus-fetch/1.0 (+local regression)"


def http_get(url: str, timeout: float = 25.0) -> bytes | None:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return None
            data = resp.read()
            return data if len(data) > 64 else None
    except (urllib.error.URLError, TimeoutError, OSError):
        return None


def valid_raster(data: bytes, path: Path) -> bool:
    path.write_bytes(data)
    if not MAGICK.is_file():
        return len(data) > 200
    p = subprocess.run(
        [str(MAGICK), "identify", "-format", "%m %w %h", str(path)],
        capture_output=True,
        text=True,
    )
    if p.returncode != 0:
        return False
    parts = (p.stdout or "").strip().split()
    if len(parts) < 3:
        return False
    fmt, w, h = parts[0].lower(), int(parts[1]), int(parts[2])
    if fmt in ("mvg", "svg", "null"):
        return False
    if w < 16 or h < 16 or max(w, h) > 4096:
        return False
    return True


def fetch_domain(domain: str) -> tuple[str, str, bytes] | None:
    domain = domain.strip().lower()
    if not domain or domain in SKIP_DOMAINS:
        return None
    if not re.fullmatch(r"[a-z0-9][a-z0-9.-]*\.[a-z]{2,63}", domain):
        return None
    urls = [
        ("clearbit", f"https://logo.clearbit.com/{domain}"),
        ("google_favicon_256", f"https://www.google.com/s2/favicons?domain={domain}&sz=256"),
        ("duckduckgo", f"https://icons.duckduckgo.com/ip3/{domain}.ico"),
    ]
    for source, url in urls:
        data = http_get(url)
        if not data:
            continue
        tmp = Path(f"/tmp/squircle-corpus-probe-{hashlib.sha256(domain.encode()).hexdigest()[:12]}.bin")
        try:
            if valid_raster(data, tmp):
                return source, url, data
        finally:
            tmp.unlink(missing_ok=True)
    return None


def load_domains(tranco_csv: Path, start_rank: int, max_scan: int) -> list[str]:
    out: list[str] = []
    with tranco_csv.open() as f:
        for line in f:
            line = line.strip()
            if not line or "," not in line:
                continue
            rank_s, dom = line.split(",", 1)
            try:
                rank = int(rank_s)
            except ValueError:
                continue
            if rank < start_rank:
                continue
            out.append(dom.strip().lower())
            if len(out) >= max_scan:
                break
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", type=int, default=1000)
    ap.add_argument("--workers", type=int, default=48)
    ap.add_argument("--start-rank", type=int, default=50)
    ap.add_argument("--max-scan", type=int, default=25000)
    ap.add_argument(
        "--tranco",
        type=Path,
        default=Path("/tmp/tranco-domains.csv"),
        help="rank,domain CSV (Tranco download)",
    )
    ap.add_argument(
        "--out-dir",
        type=Path,
        default=Path.home() / ".cursor/registry/squircle/render-csp/corpus",
    )
    args = ap.parse_args()

    if not args.tranco.is_file():
        print(f"missing tranco list: {args.tranco}", file=sys.stderr)
        print("curl -fsSL -o /tmp/tranco-domains.csv https://tranco-list.eu/download/$(curl -fsSL https://tranco-list.eu/api/lists/date/latest | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"list_id\"])')/1000000", file=sys.stderr)
        return 2

    sources_dir = args.out_dir / "sources"
    sources_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = args.out_dir / "corpus.json"

    existing: dict[str, dict] = {}
    if manifest_path.is_file():
        existing = json.loads(manifest_path.read_text())
    entries: list[dict] = list(existing.get("entries", []))
    seen_sha: set[str] = {e["sha256"] for e in entries}
    seen_dom: set[str] = {e["domain"] for e in entries}

    if len(entries) >= args.target:
        print(f"corpus already has {len(entries)} entries (target {args.target})")
        return 0

    domains = [d for d in load_domains(args.tranco, args.start_rank, args.max_scan) if d not in seen_dom]
    need = args.target - len(entries)
    print(f"fetch need={need} scan_domains={len(domains)} workers={args.workers}", file=sys.stderr)

    t0 = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(fetch_domain, d): d for d in domains}
        for fut in concurrent.futures.as_completed(futs):
            if len(entries) >= args.target:
                break
            dom = futs[fut]
            try:
                hit = fut.result()
            except Exception:
                continue
            if not hit:
                continue
            source, url, data = hit
            sha = hashlib.sha256(data).hexdigest()
            if sha in seen_sha:
                continue
            idx = len(entries) + 1
            cid = f"corpus-{idx:04d}"
            ext = "png"
            if data[:3] == b"\xff\xd8\xff":
                ext = "jpg"
            elif data[:4] == b"RIFF" and data[8:12] == b"WEBP":
                ext = "webp"
            rel = f"sources/{cid}-{dom.replace('.', '-')}.{ext}"
            out_path = args.out_dir / rel
            out_path.write_bytes(data)
            entry = {
                "id": cid,
                "domain": dom,
                "source": source,
                "url": url,
                "local": f"$CURREGISTRY/squircle/render-csp/corpus/{rel}",
                "sha256": sha,
                "expect": {
                    "clip_score_lt": 0.05,
                    "padding_px_min": 80,
                    "padding_px_max": 240,
                    "output": "1024x1024",
                },
            }
            entries.append(entry)
            seen_sha.add(sha)
            seen_dom.add(dom)
            if len(entries) % 25 == 0 or len(entries) == args.target:
                print(f"  {len(entries)}/{args.target} {dom} via {source}", file=sys.stderr)

    manifest = {
        "schema": "squircle.render-csp.corpus/v1",
        "ssot": "$CURREGISTRY/squircle/render-csp/corpus/corpus.json",
        "target": args.target,
        "count": len(entries),
        "tranco": str(args.tranco),
        "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "entries": entries,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")

    dt = time.time() - t0
    print(f"corpus count={len(entries)} manifest={manifest_path} elapsed={dt:.1f}s", file=sys.stderr)
    return 0 if len(entries) >= args.target else 1


if __name__ == "__main__":
    raise SystemExit(main())
