#!/usr/bin/env python3
"""Fetch models.dev slugs → webp/ via provider SVG then verified GitHub avatar."""
from __future__ import annotations

import json
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from models_dev_logo_lib import (
    artifact_root,
    good_svg,
    github_avatar_png,
    github_logins,
    load_policy,
    models_dev_repo,
    provider_ids_for_slug,
    run_squircle,
    squircle_cmd,
    svg_style,
    target_slugs,
    webp_dir,
)


def fetch_slug(slug: str, policy: dict) -> dict:
    out = webp_dir() / f"{slug}.webp"
    root = models_dev_repo()
    work = artifact_root() / slug
    work.mkdir(parents=True, exist_ok=True)
    rec: dict = {"slug": slug, "ok": False, "source": None, "bytes": 0}

    for pid in provider_ids_for_slug(slug, policy):
        svg = root / "providers" / pid / "logo.svg"
        if good_svg(svg, policy):
            style = svg_style(svg)
            ref = work / "anchor.svg"
            if not ref.exists() or ref.read_bytes() != svg.read_bytes():
                ref.write_bytes(svg.read_bytes())
            if run_squircle(squircle_cmd(svg, out, policy, style)):
                rec.update(
                    {
                        "ok": True,
                        "source": f"svg:providers/{pid}/logo.svg",
                        "bytes": out.stat().st_size,
                        "style": style,
                    }
                )
                return rec

    lab_svg = root / "labs" / slug / "logo.svg"
    if good_svg(lab_svg, policy):
        style = svg_style(lab_svg)
        if run_squircle(squircle_cmd(lab_svg, out, policy, style)):
            rec.update(
                {
                    "ok": True,
                    "source": f"svg:labs/{slug}/logo.svg",
                    "bytes": out.stat().st_size,
                    "style": style,
                }
            )
            return rec

    for login in github_logins(slug, policy):
        png = work / f"github-{login}.png"
        if github_avatar_png(login, png, policy) and run_squircle(squircle_cmd(png, out, policy)):
            rec.update(
                {
                    "ok": True,
                    "source": f"github:{login}",
                    "bytes": out.stat().st_size,
                }
            )
            return rec

    rec["error"] = "no_source"
    return rec


def main() -> int:
    policy = load_policy()
    slugs = target_slugs(policy)
    if not slugs:
        print("no slugs", file=sys.stderr)
        return 1
    if not models_dev_repo().is_dir():
        print(f"missing MODELS_DEV_REPO {models_dev_repo()}", file=sys.stderr)
        return 1

    only = os.environ.get("LOGO_SLUGS", "").strip()
    if only:
        want = {s.strip() for s in only.split(",") if s.strip()}
        slugs = [s for s in slugs if s in want]

    workers = int(os.environ.get("LOGO_FETCH_WORKERS", "8"))
    results: list[dict] = []
    artifact_root().mkdir(parents=True, exist_ok=True)
    ledger = artifact_root() / "ledger.jsonl"

    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(fetch_slug, s, policy): s for s in slugs}
        for fut in as_completed(futs):
            r = fut.result()
            results.append(r)
            tag = "OK" if r["ok"] else "FAIL"
            print(f"{tag}\t{r['slug']}\t{r.get('source') or r.get('error')}")

    ledger.write_text("\n".join(json.dumps(x) for x in sorted(results, key=lambda x: x["slug"])) + "\n")
    fail = [r["slug"] for r in results if not r["ok"]]
    print(f"# ledger {ledger} ok={len(results)-len(fail)}/{len(results)}")
    return 2 if fail else 0


if __name__ == "__main__":
    import os

    sys.exit(main())
