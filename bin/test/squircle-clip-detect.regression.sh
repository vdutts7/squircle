#!/usr/bin/env bash
# PARITY: C-CLIP-DETECT — default opaque path is padding, never fill-only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SQUIRCLE_SH="${SQUIRCLE_SH:-$ROOT/bin/squircle.sh}"
CONTRACT="$ROOT/registry/contracts/clip-detect.json"
MAGICK="${MAGICK:-/opt/homebrew/bin/magick}"
[[ -x "$MAGICK" ]] || MAGICK=/usr/local/bin/magick
pass=0; fail=0
ok(){ echo "  ok $1" >&2; pass=$((pass+1)); }
bad(){ echo "  FAIL $1" >&2; fail=$((fail+1)); }
[[ -x "$SQUIRCLE_SH" && -f "$CONTRACT" && -x "$MAGICK" ]] || { bad "prereqs"; exit 2; }
ok "prereqs"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/squircle-clip-regr.XXXXXX")"
trap '/usr/bin/trash "$WORK" 2>/dev/null || true' EXIT
FIX="$WORK/plate.png"; OUT="$WORK/out.webp"
"$MAGICK" -size 512x512 xc:'#336699' "$FIX"
status="$("$SQUIRCLE_SH" "$FIX" --out "$OUT" 2>&1)" || { bad "exit"; echo "$status" >&2; exit 2; }
echo "$status" >&2
echo "$status" | grep -q 'padding' && ok "status padding" || bad "status not padding: $status"
echo "$status" | grep -q 'mode: fill' && bad "fill-only under default clip-detect" || ok "rejects fill-only"
pad="$(printf '%s\n' "$status" | sed -nE 's/.*padding ([0-9]+)px.*/\1/p' | head -1)"
[[ -n "$pad" ]] || pad=0
min="$(python3 -c "import json;print(json.load(open('$CONTRACT'))['gates']['min_pad_px'])")"
(( pad >= min )) && ok "pad $pad >= $min" || bad "pad $pad < $min"
echo "squircle-clip-detect.regression pass=$pass fail=$fail" >&2
(( fail == 0 ))
