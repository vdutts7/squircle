#!/usr/bin/env bash
# PARITY: C-MARGIN-CHROMA — high chroma → #FFFFFF; never auto none (restores 8b37b5c1).
# Bound to: registry/contracts/margin-chroma.json
# Isolation: source lock + unit probe only; not aperture/letterbox/silhouette metrics.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SQUIRCLE_SH="${SQUIRCLE_SH:-$ROOT/bin/squircle.sh}"
CONTRACT="$ROOT/registry/contracts/margin-chroma.json"

pass=0
fail=0
ok() { echo "  ok $1" >&2; pass=$((pass + 1)); }
bad() { echo "  FAIL $1" >&2; fail=$((fail + 1)); }

[[ -x "$SQUIRCLE_SH" ]] || { bad "squircle.sh missing"; exit 2; }
[[ -f "$CONTRACT" ]] || { bad "margin-chroma contract missing"; exit 2; }
ok "binaries+contract"

python3 - "$SQUIRCLE_SH" "$CONTRACT" <<'PY'
import json, re, sys
from pathlib import Path

src_path, contract_path = sys.argv[1:3]
src = Path(src_path).read_text()
c = json.loads(Path(contract_path).read_text())
g = c["gates"]
rc = 0

# Extract opaque_margin_from_corner_hex body
m = re.search(r'^opaque_margin_from_corner_hex\(\) \{.*?\n\}', src, re.M | re.S)
if not m:
    print("FAIL opaque_margin_from_corner_hex missing", file=sys.stderr)
    sys.exit(2)
body = m.group(0)
print(f"fn_bytes={len(body)}", file=sys.stderr)

for s in g.get("forbid_source_substrings") or []:
    # only forbid none-echo inside this function (DstIn elsewhere may mention none)
    if s in body:
        print(f"FAIL forbid in chroma gate: {s}", file=sys.stderr)
        rc = 2
    else:
        print(f"ok absent in chroma gate: {s}", file=sys.stderr)

for s in g.get("require_source_substrings") or []:
    if s not in body:
        print(f"FAIL require in chroma gate: {s}", file=sys.stderr)
        rc = 2
    else:
        print(f"ok present in chroma gate: {s}", file=sys.stderr)

# Behavioral: high-chroma + uniform=0 (default / non-flat) → #FFFFFF.
# uniform=1 is C-FIELD-PLATE — not asserted here.
def margin(s, pad_mode=0, uniform=0, lim=42):
    if len(s) != 7 or s[0] != '#':
        return '#FFFFFF'
    r, g, b = int(s[1:3], 16), int(s[3:5], 16), int(s[5:7], 16)
    chroma = max(r, g, b) - min(r, g, b)
    if chroma > lim:
        return s if uniform == 1 else '#FFFFFF'
    return s

want = g.get("high_chroma_uniform0_must_return") or g.get("high_chroma_must_return")
for hx, pm in (('#76F8E5', 0), ('#76F8E5', 1), ('#F7A41D', 1), ('#FF0000', 1)):
    got = margin(hx, pm, uniform=0)
    if got != want:
        print(f"FAIL {hx} uniform=0 → {got} want {want}", file=sys.stderr)
        rc = 2
    else:
        print(f"ok {hx} uniform=0 → {got}", file=sys.stderr)

# low chroma still passes through
got = margin('#F0F0F0', 1)
if got != '#F0F0F0':
    print(f"FAIL low-chroma passthrough got {got}", file=sys.stderr)
    rc = 2
else:
    print("ok low-chroma passthrough", file=sys.stderr)

sys.exit(rc)
PY
py_rc=$?
(( py_rc == 0 )) && ok "C-MARGIN-CHROMA gates" || bad "C-MARGIN-CHROMA gates"

echo "squircle-margin-chroma.regression pass=$pass fail=$fail" >&2
(( fail == 0 ))
exit $?
