#!/usr/bin/env bash
# PARITY: default squircle bg — full-res corner sample + padding fill (no 64x64 bleed).
# Bound to: bin/squircle.sh#sample_corner_bg_hex, bin/get-bg-color.sh
# Lives: $SQUIRCLE/bin/test/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SQUIRCLE_SH="${SQUIRCLE_SH:-$ROOT/bin/squircle.sh}"
GET_BG="${GET_BG:-$ROOT/bin/get-bg-color.sh}"
MAGICK="${MAGICK:-/opt/homebrew/bin/magick}"
[[ -x "$MAGICK" ]] || MAGICK=/usr/local/bin/magick

pass=0
fail=0
ok() { echo "  ok $1" >&2; pass=$((pass + 1)); }
bad() { echo "  FAIL $1" >&2; fail=$((fail + 1)); }

[[ -x "$SQUIRCLE_SH" ]] || { bad "squircle.sh missing"; exit 2; }
[[ -x "$GET_BG" ]] || { bad "get-bg-color.sh missing"; exit 2; }
[[ -x "$MAGICK" ]] || { bad "magick missing"; exit 2; }
ok "binaries present"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/squircle-bg-regr.XXXXXX")"
cleanup() { /usr/bin/trash "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# Bleed trap (landscape): white canvas + plasma plate. Resize-to-64x64 before
# crop contaminates corners; full-res corner crop must stay #FFFFFF.
FIX="$WORK/bleed-trap.jpeg"
"$MAGICK" -size 488x349 xc:white \
  \( -size 420x300 plasma:red-yellow \) -gravity center -compose over -composite \
  "$FIX"
ok "fixture bleed-trap"

# --- get-bg-color: opaque tile → OPAQUE (base layer skipped) ---
bg="$("$GET_BG" "$FIX" 2>/dev/null || true)"
[[ "$bg" == "OPAQUE" ]] && ok "get-bg → OPAQUE" || bad "get-bg expected OPAQUE got '$bg'"

# --- prove 64x64-first would bleed (negative control; not production path) ---
# Crop 16×16 after downscale: larger patch still catches plasma bleed into corners.
# (Production sample is 4×4 full-res — different failure mode, covered by near-edge below.)
bleed="$("$MAGICK" "$FIX" -resize 64x64 -crop 16x16+0+0 +repage -scale 1x1! \
  -format '%[fx:round(255*u.r)]' info:)"
[[ "$bleed" != "255" ]] && ok "64x64-first bleeds (r=$bleed)" || bad "64x64-first unexpectedly pure white"

# --- full-res corner crop stays white (production patch size = 4×4) ---
pure="$("$MAGICK" "$FIX" -crop 4x4+0+0 +repage -scale 1x1! \
  -format '%[fx:round(255*u.r)]' info:)"
[[ "$pure" == "255" ]] && ok "full-res corner pure white" || bad "full-res corner r=$pure"

# --- source lock: sample_corner_bg_hex must not resize-before-crop ---
fn_body="$(sed -n '/^sample_corner_bg_hex()/,/^}/p' "$SQUIRCLE_SH")"
if printf '%s\n' "$fn_body" | grep -qE -- '-resize[[:space:]]+64x64'; then
  bad "sample_corner still resize-64x64-before-crop"
else
  ok "sample_corner no resize-first"
fi

# --- default squircle: aperture-safe padding + white letterbox (landscape → vertical margin) ---
OUT="$WORK/out.webp"
set +e
status="$("$SQUIRCLE_SH" "$FIX" --out "$OUT" 2>&1)"
rc=$?
set -e
echo "$status" >&2
(( rc == 0 )) && ok "squircle exit 0" || bad "squircle exit $rc"
[[ -f "$OUT" ]] && ok "webp written" || bad "webp missing"

# Default pad must clear aperture (≥ mask mid-side + APERTURE_CLEARANCE); not the old flush-100.
pad_px="$(printf '%s\n' "$status" | sed -nE 's/.*padding ([0-9]+)px.*/\1/p' | head -1)"
[[ -n "$pad_px" ]] && ok "padding mode ${pad_px}px" || bad "status missing padding Npx: $status"
(( pad_px >= 148 )) && ok "aperture-safe pad (>=148)" || bad "pad $pad_px flush/unsafe (<148)"

# y=150 letterbox inside mask: must be white opaque (not plasma bleed)
r="$("$MAGICK" "$OUT" -crop 1x1+512+150 -format '%[fx:round(255*u.r)]' info:)"
g="$("$MAGICK" "$OUT" -crop 1x1+512+150 -format '%[fx:round(255*u.g)]' info:)"
b="$("$MAGICK" "$OUT" -crop 1x1+512+150 -format '%[fx:round(255*u.b)]' info:)"
a="$("$MAGICK" "$OUT" -crop 1x1+512+150 -format '%[fx:u.a]' info:)"
if (( r >= 250 && g >= 250 && b >= 250 )); then
  ok "padding fill white (rgb=$r,$g,$b)"
else
  bad "padding fill not white: rgb=$r,$g,$b"
fi
awk -v a="$a" 'BEGIN{exit !(a+0 >= 0.99)}' && ok "padding opaque" || bad "padding alpha=$a"

# center keeps plasma chroma (not flattened white)
cr="$("$MAGICK" "$OUT" -crop 1x1+512+512 -format '%[fx:round(255*u.r)]' info:)"
cg="$("$MAGICK" "$OUT" -crop 1x1+512+512 -format '%[fx:round(255*u.g)]' info:)"
cb="$("$MAGICK" "$OUT" -crop 1x1+512+512 -format '%[fx:round(255*u.b)]' info:)"
# not near-white
if (( cr < 250 || cg < 250 || cb < 250 )); then
  ok "center keeps plate chroma (rgb=$cr,$cg,$cb)"
else
  bad "center washed to white rgb=$cr,$cg,$cb"
fi

# Near-rim ink trap (fluentd-class): dark mark inside former 16×16 BR corner, outside 4×4.
# 16×16 mean → taupe pad; production 4×4 sample must keep white letterbox.
NEAR="$WORK/near-edge.jpeg"
"$MAGICK" -size 472x423 xc:white \
  -fill '#1B1F20' -draw 'rectangle 456,407 467,418' \
  "$NEAR"
ok "fixture near-edge"
# Negative control: 16×16 BR mean is not white
near16="$("$MAGICK" "$NEAR" -crop 16x16+456+407 +repage -scale 1x1! \
  -format '%[fx:round(255*u.r)]' info:)"
[[ "$near16" != "255" ]] && ok "16x16 BR contaminated (r=$near16)" || bad "16x16 BR unexpectedly white"
NEAR_OUT="$WORK/near-edge.webp"
set +e
near_status="$("$SQUIRCLE_SH" "$NEAR" --out "$NEAR_OUT" 2>&1)"
near_rc=$?
set -e
echo "$near_status" >&2
(( near_rc == 0 )) && ok "near-edge squircle exit 0" || bad "near-edge squircle exit $near_rc"
nr="$("$MAGICK" "$NEAR_OUT" -crop 1x1+512+150 -format '%[fx:round(255*u.r)]' info:)"
ng="$("$MAGICK" "$NEAR_OUT" -crop 1x1+512+150 -format '%[fx:round(255*u.g)]' info:)"
nb="$("$MAGICK" "$NEAR_OUT" -crop 1x1+512+150 -format '%[fx:round(255*u.b)]' info:)"
if (( nr >= 250 && ng >= 250 && nb >= 250 )); then
  ok "near-edge padding white (rgb=$nr,$ng,$nb)"
else
  bad "near-edge padding taupe: rgb=$nr,$ng,$nb"
fi

echo "squircle-bg-default.regression pass=$pass fail=$fail" >&2
(( fail == 0 )) && exit 0
exit 2
