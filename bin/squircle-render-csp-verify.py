#!/usr/bin/env python3
"""Assert render CSP plan + output against registry fixture expect block."""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path


def chroma(hex_s: str) -> int:
    if not re.fullmatch(r"#[0-9A-Fa-f]{6}", hex_s):
        return 999
    r = int(hex_s[1:3], 16)
    g = int(hex_s[3:5], 16)
    b = int(hex_s[5:7], 16)
    return max(r, g, b) - min(r, g, b)


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: squircle-render-csp-verify.py <expect.json> <plan.json> <output.webp>", file=sys.stderr)
        return 2
    expect = json.loads(Path(sys.argv[1]).read_text() if Path(sys.argv[1]).exists() else sys.argv[1])
    plan = json.loads(Path(sys.argv[2]).read_text())
    out = Path(sys.argv[3])
    errs: list[str] = []

    if expect.get("source_class") and plan.get("source_class") != expect["source_class"]:
        errs.append(f"source_class want {expect['source_class']} got {plan.get('source_class')}")

    cs = plan.get("clip_score")
    if cs is not None and "clip_score_lt" in expect and float(cs) >= float(expect["clip_score_lt"]):
        errs.append(f"clip_score {cs} >= {expect['clip_score_lt']}")

    p = int(plan.get("padding_px", -1))
    if "padding_px_min" in expect and p < int(expect["padding_px_min"]):
        errs.append(f"padding_px {p} < min {expect['padding_px_min']}")
    if "padding_px_max" in expect and p > int(expect["padding_px_max"]):
        errs.append(f"padding_px {p} > max {expect['padding_px_max']}")

    m = plan.get("margin_hex", "")
    if expect.get("margin_hex") and m.upper() != expect["margin_hex"].upper():
        errs.append(f"margin_hex want {expect['margin_hex']} got {m}")
    if out.is_file() and expect.get("output"):
        magick = "/opt/homebrew/bin/magick"
        if not Path(magick).is_file():
            magick = "/usr/local/bin/magick"
        dim = subprocess.run(
            [magick, "identify", "-format", "%wx%h", str(out)],
            capture_output=True,
            text=True,
            check=False,
        )
        got = (dim.stdout or "").strip()
        if got != expect["output"]:
            errs.append(f"output size want {expect['output']} got {got}")

    if errs:
        for e in errs:
            print(f"FAIL: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
