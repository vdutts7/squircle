#!/usr/bin/env python3
"""Operator eyeball gate. Opens render_path + anchor side-by-side, records verdict.

verdict ∈ {approved, wrong_brand, low_quality}
wrong_brand → ledger verify_status rewritten to fail_human_override so the
slug cycles back through fetch (next source in sources.json) on the next run.
"""
from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
REG = REPO / "registry" / "logo-corpus"
SLUGS = REG / "slugs.json"
LEDGER = REG / "ledger"
EYE = REG / "eyeball.json"


def shim(msg: str, fix: str, code: int = 80) -> None:
    sys.stderr.write(f"🔴 logo-corpus-review: {msg} (exit {code})\n  run: {fix}\n")
    sys.exit(code)


def preview(paths: list[str]) -> None:
    if not paths:
        return
    try:
        subprocess.run(["open", "-a", "Preview", "-g", *paths], check=False)
    except Exception as e:
        sys.stderr.write(f"    open: {e}\n")


def main() -> int:
    if not SLUGS.is_file():
        shim("slugs.json missing", "python3 bin/logo-corpus-build-slugs.py", 80)
    args = sys.argv[1:]
    batch = 10
    only: list[str] = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--batch" and i + 1 < len(args):
            batch = int(args[i + 1]); i += 2
        else:
            only.append(a); i += 1

    doc = json.loads(SLUGS.read_text())
    eye_doc = json.loads(EYE.read_text())
    eye = eye_doc.setdefault("slugs", {})

    queue = []
    for s in doc["slugs"]:
        if not s["in_scope"]:
            continue
        if only and s["slug"] not in only:
            continue
        lf = LEDGER / f"{s['slug']}.json"
        if not lf.is_file():
            continue
        row = json.loads(lf.read_text())
        if row.get("verify_status") != "pass":
            continue
        if eye.get(s["slug"], {}).get("human_verdict") == "approved":
            continue
        queue.append((s["slug"], row))
        if len(queue) >= batch:
            break

    if not queue:
        print(json.dumps({"queue": 0, "msg": "nothing pending"}, indent=2))
        return 0

    paths = []
    for slug, row in queue:
        if row.get("render_path"):
            paths.append(row["render_path"])
    preview(paths)

    for slug, row in queue:
        print(f"\nslug: {slug}")
        print(f"  winner_source : {row.get('winner_source')}")
        print(f"  output_phash  : {row.get('output_phash')}")
        print(f"  render        : {row.get('render_path')}")
        v = input("  verdict [a=approved | w=wrong_brand | q=low_quality | s=skip]: ").strip().lower()
        if v == "s":
            continue
        verdict = {"a": "approved", "w": "wrong_brand", "q": "low_quality"}.get(v)
        if not verdict:
            print("  skipped (unrecognized)")
            continue
        eye[slug] = {"human_verdict": verdict, "reviewed_at": int(time.time())}
        if verdict == "wrong_brand":
            row["verify_status"] = "fail_human_override"
            (LEDGER / f"{slug}.json").write_text(json.dumps(row, indent=2) + "\n")

    EYE.write_text(json.dumps(eye_doc, indent=2) + "\n")
    print(json.dumps({"reviewed": len(queue)}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
