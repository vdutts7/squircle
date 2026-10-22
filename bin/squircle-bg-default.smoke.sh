#!/usr/bin/env zsh
# smoke: default bg #fff without --bg; --bg #hex still works
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SH="$ROOT/bin/squircle.sh"
MAGICK=/opt/homebrew/bin/magick
[[ -x "$MAGICK" ]] || MAGICK=/usr/local/bin/magick

TMP=$(mktemp -d)
trap 'trash "$TMP" 2>/dev/null || rm -rf "$TMP"' EXIT

"$MAGICK" -size 128x128 xc:none \
  -fill black -draw "rectangle 0,0 18,128" -draw "rectangle 110,0 128,128" \
  -fill '#2255aa' -draw "circle 64,64 64,18" "$TMP/in.png"

"$SH" "$TMP/in.png" --out "$TMP/default.webp" --size 256 --no-clip-detect
m1=$("$MAGICK" "$TMP/default.webp" -background white -alpha remove -crop 8x8+0+0 +repage -format '%[fx:mean]' info:)
awk -v m="$m1" 'BEGIN{ exit !(m+0 >= 0.85) }' || { echo "FAIL default corner mean=$m1"; exit 1; }

line=$("$SH" "$TMP/in.png" --out "$TMP/green.webp" --size 256 --no-clip-detect --bg '#00ff00' 2>&1 | grep '🟢' || true)
[[ -f "$TMP/green.webp" ]] || { echo "FAIL --bg render"; exit 1; }
[[ "$line" == *'#00ff00'* ]] || { echo "FAIL --bg status line: $line"; exit 1; }

echo "squircle-bg-default.smoke pass"
