#!/usr/bin/env python3
"""Build registry/logo-corpus/slugs.json from the models.dev clone.

In-scope rules are declarative and live in this file only:
  - providers/<id> is in_scope unless <id> matches VARIANT_REGEX, OR
    provider.toml declares a `parent` field.
  - labs/<id>  always in_scope.
  - models/<id> always in_scope.

Union of in-scope slugs is the webp universe. No other agent writes to slugs.json.
Exit non-zero + shim-as-a-log stderr on any sanity failure (missing clone, dupes).
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

VARIANT_REGEX = re.compile(
    r"-(coding-plan|token-plan|code-plan|step-plan)(-|$)"
    r"|-vertex(-|$)"
    r"|-cn$"
)

REPO = Path(__file__).resolve().parent.parent
REG = REPO / "registry" / "logo-corpus"
SLUGS_JSON = REG / "slugs.json"


def fail(msg: str, fix: str, code: int = 2) -> None:
    sys.stderr.write(f"🔴 logo-corpus-build-slugs: {msg} (exit {code})\n  run: {fix}\n")
    sys.exit(code)


def read_provider_toml(path: Path) -> dict:
    text = path.read_text(errors="replace")
    data: dict = {}
    for line in text.splitlines():
        m = re.match(r"^([a-zA-Z_][\w-]*)\s*=\s*(.+?)\s*$", line.strip())
        if not m:
            continue
        key, raw = m.group(1), m.group(2).strip()
        if raw.startswith('"') and raw.endswith('"'):
            data[key] = raw[1:-1]
    return data


def build() -> dict:
    clone = Path("/private/tmp/models.dev-dev")
    if not clone.is_dir():
        fail(
            "models.dev clone missing",
            f"git clone https://github.com/sst/models.dev {clone}",
            code=10,
        )

    slugs: dict[str, dict] = {}

    for source in ("providers", "labs", "models"):
        src_dir = clone / source
        if not src_dir.is_dir():
            continue
        for d in sorted(src_dir.iterdir()):
            if not d.is_dir():
                continue
            slug = d.name
            toml = d / "provider.toml"
            parent = None
            if toml.is_file():
                parent = read_provider_toml(toml).get("parent")

            variant = bool(VARIANT_REGEX.search(slug))
            in_scope = True
            reason = None
            if source == "providers":
                if variant:
                    in_scope = False
                    reason = "routing_variant"
                elif parent:
                    in_scope = False
                    reason = f"aliased_to_parent:{parent}"

            logo = d / "logo.svg"
            entry = slugs.setdefault(
                slug,
                {
                    "slug": slug,
                    "sources": [],
                    "in_scope": True,
                    "reason_if_excluded": None,
                },
            )
            entry["sources"].append(source)
            if logo.is_file():
                entry[f"{source}_svg"] = str(logo)
            if not in_scope:
                entry["in_scope"] = False
                entry["reason_if_excluded"] = reason

    return {
        "$schema": "v1",
        "variant_regex": VARIANT_REGEX.pattern,
        "slugs": sorted(slugs.values(), key=lambda s: s["slug"]),
    }


def main() -> int:
    REG.mkdir(parents=True, exist_ok=True)
    doc = build()
    SLUGS_JSON.write_text(json.dumps(doc, indent=2, sort_keys=False) + "\n")
    in_scope = sum(1 for s in doc["slugs"] if s["in_scope"])
    out_scope = len(doc["slugs"]) - in_scope
    print(json.dumps({
        "wrote": str(SLUGS_JSON),
        "total": len(doc["slugs"]),
        "in_scope": in_scope,
        "out_of_scope": out_scope,
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
