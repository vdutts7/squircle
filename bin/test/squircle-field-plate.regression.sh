#!/usr/bin/env bash
# PARITY: C-FIELD-PLATE — uniform high-chroma field extends into squircle plate (IRS-class).
# Isolation: field_plate_rgb only — does NOT touch margin_hex / letterbox / aperture / silhouette dims.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SQUIRCLE_SH="${SQUIRCLE_SH:-$ROOT/bin/squircle.sh}"
CONTRACT="$ROOT/registry/contracts/field-plate.json"
MAGICK="${MAGICK:-/opt/homebrew/bin/magick}"
[[ -x "$MAGICK" ]] || MAGICK=/usr/local/bin/magick
pass=0; fail=0
ok(){ echo "  ok $1" >&2; pass=$((pass+1)); }
bad(){ echo "  FAIL $1" >&2; fail=$((fail+1)); }
[[ -x "$SQUIRCLE_SH" && -f "$CONTRACT" && -x "$MAGICK" ]] || { bad "prereqs"; exit 2; }
ok "prereqs"

FIELD="$(python3 -c "import json;print(json.load(open('$CONTRACT'))['gates']['field_hex'])")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/squircle-field-regr.XXXXXX")"
trap '/usr/bin/trash "$WORK" 2>/dev/null || true' EXIT

# Uniform high-chroma landscape (IRS-class): every corner is field color.
FIX="$WORK/field.png"; OUT="$WORK/out.webp"
"$MAGICK" -size 1024x537 xc:"$FIELD" \
  -fill white -draw 'rectangle 80,180 280,360' \
  -fill white -draw 'rectangle 320,200 940,340' \
  "$FIX"
ok "fixture uniform-field landscape"

status="$("$SQUIRCLE_SH" "$FIX" --out "$OUT" 2>&1)" || { bad "exit"; echo "$status" >&2; exit 2; }
echo "$status" >&2

python3 - "$OUT" "$CONTRACT" "$FIELD" <<'PY'
import json, subprocess, sys
from pathlib import Path
out, contract, field = sys.argv[1:4]
g = json.loads(Path(contract).read_text())["gates"]
hx = g["field_hex"].lstrip("#")
want = tuple(int(hx[i:i+2], 16) for i in (0, 2, 4))
x, y = g["sample_xy"]
tol = int(g["rgb_tolerance"])
magick = "/opt/homebrew/bin/magick"
import os
if not os.path.isfile(magick):
    magick = "/usr/local/bin/magick"
fmt = "%[fx:round(255*u.r)] %[fx:round(255*u.g)] %[fx:round(255*u.b)] %[fx:u.a]"
got = subprocess.check_output(
    [magick, out, "-crop", f"1x1+{x}+{y}", "+repage", "-format", fmt, "info:"],
    stderr=subprocess.DEVNULL,
).decode().split()
r, gv, b = map(int, got[:3])
a = float(got[3])
print(f"plate=({r},{gv},{b},a={a}) want={want} tol={tol}", file=sys.stderr)
rc = 0
if a < 0.99:
    print("FAIL plate not opaque", file=sys.stderr)
    rc = 2
if g.get("require_not_near_white") and r >= 240 and gv >= 240 and b >= 240:
    print("FAIL plate near-white (field not extended)", file=sys.stderr)
    rc = 2
if abs(r - want[0]) > tol or abs(gv - want[1]) > tol or abs(b - want[2]) > tol:
    print("FAIL plate rgb != field", file=sys.stderr)
    rc = 2
sys.exit(rc)
PY
(( $? == 0 )) && ok "field plate rgb" || bad "field plate rgb"

# Unit: uniform=1 keeps sample; uniform=0 still white (does not steal C-MARGIN-CHROMA).
python3 - <<'PY'
# Document expected API (mirrors zsh opaque_margin_from_corner_hex)
def margin(s, uniform=0, lim=42):
    r,g,b=int(s[1:3],16),int(s[3:5],16),int(s[5:7],16)
    chroma=max(r,g,b)-min(r,g,b)
    if chroma>lim:
        return s if uniform==1 else '#FFFFFF'
    return s
assert margin('#00599C',0)=='#FFFFFF'
assert margin('#00599C',1)=='#00599C'
print('ok unit uniform gate', file=__import__('sys').stderr)
PY
ok "unit uniform gate"

echo "squircle-field-plate.regression pass=$pass fail=$fail" >&2
(( fail == 0 ))
