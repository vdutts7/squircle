#!/usr/bin/env python3
"""Vendored metasearch spray — public subset of harness $CURTOOLS/warch/metasearch.
5 engines (ddg_lite, bing, ecosia, startpage, brave). CLI + importable `spray()`.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time

from .core import log, merge, expand_query, SLA_SECONDS, REQ_TIMEOUT
from .engines import PAGE_FETCHERS, MULTI_STEP, SINGLE_PAGE, ALL_ENGINES, DEFAULT

try:
    from curl_cffi.requests import AsyncSession
except ImportError:
    raise SystemExit("install: $SQUIRCLE/bin/.venv/bin/pip install curl_cffi beautifulsoup4")

DEFAULT_PAGES = 10
DEFAULT_INFLIGHT = 64
CONSERVATIVE_PAGES = 3


def _morton2(x, y, bits=12):
    z = 0
    for i in range(bits):
        z |= ((x >> i) & 1) << (2 * i)
        z |= ((y >> i) & 1) << (2 * i + 1)
    return z


def z_schedule(queries, engine_list, pages):
    jobs = []
    for qi, q in enumerate(queries):
        for ei, eng in enumerate(engine_list):
            if eng in MULTI_STEP:
                continue
            n = 1 if eng in SINGLE_PAGE else pages
            for pi in range(n):
                key = _morton2(ei, pi)
                jobs.append((key, q, eng, pi))
    jobs.sort(key=lambda t: t[0])
    return [(q, eng, pi) for _, q, eng, pi in jobs]


async def _boxed(deadline, coro):
    rem = deadline - time.monotonic()
    if rem <= 0:
        return []
    try:
        return await asyncio.wait_for(coro, timeout=min(REQ_TIMEOUT, rem))
    except Exception:
        return []


async def _spray_blast(queries, pages, engine_list, max_inflight=DEFAULT_INFLIGHT):
    t0 = time.monotonic()
    deadline = t0 + SLA_SECONDS
    jobs = z_schedule(queries, engine_list, pages)
    log("🔵", "zmap", f"{len(jobs)} jobs sla={SLA_SECONDS}s inflight={max_inflight}")

    raw = []
    sem = asyncio.Semaphore(max_inflight)

    async with AsyncSession(impersonate="chrome131") as session:

        async def run_page(q, eng, pi):
            async with sem:
                return await _boxed(deadline, PAGE_FETCHERS[eng](session, q, pi))

        tasks = [asyncio.create_task(run_page(q, eng, pi)) for q, eng, pi in jobs]
        rem = max(0.0, deadline - time.monotonic())
        done, pending = await asyncio.wait(tasks, timeout=rem)
        for t in pending:
            t.cancel()
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)
            log("🌕", "sla", f"cut {len(pending)} jobs at {SLA_SECONDS}s cap")

        for t in done:
            try:
                hits = t.result()
                if hits:
                    raw.extend(hits)
            except Exception:
                pass

    elapsed = time.monotonic() - t0
    log("🔵", "zmap", f"wall {elapsed:.1f}s")
    return raw, elapsed


def spray(query, pages=DEFAULT_PAGES, engines=None, expand=0, max_inflight=DEFAULT_INFLIGHT):
    if not engines or engines == ["default"]:
        engine_list = sorted(DEFAULT)
    elif engines == ["all"]:
        engine_list = sorted(ALL_ENGINES.keys())
    else:
        engine_list = [e for e in engines if e in ALL_ENGINES]

    queries = expand_query(query, expand) if expand > 1 else [query]
    log("🔵", "spray", f"query='{query}' pages={pages} engines={engine_list}")

    raw, elapsed = asyncio.run(_spray_blast(queries, pages, engine_list, max_inflight))
    merged = merge(raw)
    dedup = (1 - len(merged) / max(len(raw), 1)) * 100
    log("🟢", "spray", f"{len(raw)} raw → {len(merged)} unique ({dedup:.0f}% dedup) in {elapsed:.1f}s")
    return merged


def main():
    p = argparse.ArgumentParser(description="squircle vendored metasearch spray")
    p.add_argument("query")
    p.add_argument("--pages", type=int, default=DEFAULT_PAGES)
    p.add_argument("--engines", nargs="+", default=["default"])
    p.add_argument("--expand", type=int, default=0, metavar="N")
    p.add_argument("--out", default=None)
    p.add_argument("--pretty", action="store_true")
    p.add_argument("--conservative", action="store_true")
    p.add_argument("--inflight", type=int, default=DEFAULT_INFLIGHT)
    args = p.parse_args()

    pages = CONSERVATIVE_PAGES if args.conservative else args.pages
    engines = ["default"] if args.conservative else args.engines

    results = spray(args.query, pages=pages, engines=engines, expand=args.expand, max_inflight=args.inflight)

    indent = 2 if args.pretty else None
    payload = "\n".join(json.dumps(r, ensure_ascii=False, indent=indent) for r in results) + "\n"
    if args.out:
        with open(args.out, "w") as f:
            f.write(payload)
        print(f"🟢 [spray] → {args.out} ({len(results)} results)", file=sys.stderr)
    else:
        print(payload, end="")


if __name__ == "__main__":
    main()
