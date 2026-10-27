#!/usr/bin/env bash
# PARITY: C-BG-OVERRIDE — --bg #HEX forces plate pixel color.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SQUIRCLE_SH="${SQUIRCLE_SH:-$ROOT/bin/squircle.sh}"
CONTRACT="$ROOT/registry/contracts/bg-override.json"
MAGICK="${MAGICK:-/opt/homebrew/bin/magick}"
[[ -x "$MAGICK" ]] || MAGICK=/usr/local/bin/magick
pass=0; fail=0
ok(){ echo "  ok $1" >&2; pass=$((pass+1)); }
bad(){ echo "  FAIL $1" >&2; fail=$((fail+1)); }
[[ -x "$SQUIRCLE_SH" && -f "$CONTRACT" && -x "$MAGICK" ]] || { bad "prereqs"; exit 2; }
ok "prereqs"
BG="$(python3 -c "import json;print(json.load(open('$CONTRACT'))['gates']['bg_hex'])")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/squircle-bgo-regr.XXXXXX")"
trap '/usr/bin/trash "$WORK" 2>/dev/null || true' EXIT
FIX="$WORK/land.png"; OUT="$WORK/out.webp"
# landscape high-chroma so default margin would be white without --bg
"$MAGICK" -size 620x300 xc:'#76F8E5' "$FIX"
status="$("$SQUIRCLE_SH" "$FIX" --bg "$BG" --padding 200 --out "$OUT" 2>&1)" || { bad "exit"; echo "$status" >&2; exit 2; }
echo "$status" >&2
python3 - "$OUT" "$CONTRACT" <<'PY'
import json, subprocess, sys
from pathlib import Path
out, contract = sys.argv[1:3]
g = json.loads(Path(contract).read_text())["gates"]
hx = g["bg_hex"].lstrip("#")
want = tuple(int(hx[i:i+2], 16) for i in (0, 2, 4))
x, y = g["sample_xy"]
tol = int(g["rgb_tolerance"])
magick = "/opt/homebrew/bin/magick"
import os
if not os.path.isfile(magick): magick = "/usr/local/bin/magick"
fmt = f"%[fx:round(255*u.r)] %[fx:round(255*u.g)] %[fx:round(255*u.b)] %[fx:u.a]"
got = subprocess.check_output(
    [magick, out, "-crop", f"1x1+{x}+{y}", "+repage", "-format", fmt, "info:"],
    stderr=subprocess.DEVNULL,
).decode().split()
r, g_, b = map(int, got[:3])
a = float(got[3])
print(f"sample=({r},{g_},{b},a={a}) want={want} tol={tol}", file=sys.stderr)
if a < 0.99:
    print("FAIL sample not opaque", file=sys.stderr)
    sys.exit(2)
if abs(r-want[0])>tol or abs(g_-want[1])>tol or abs(b-want[2])>tol:
    print("FAIL rgb mismatch", file=sys.stderr)
    sys.exit(2)
sys.exit(0)
PY
(( $? == 0 )) && ok "override pixel rgb" || bad "override pixel rgb"
echo "squircle-bg-override.regression pass=$pass fail=$fail" >&2
(( fail == 0 ))
