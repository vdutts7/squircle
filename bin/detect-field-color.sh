#!/usr/bin/env zsh
# detect-field-color — matte hex for squircle margin (SSOT).
# Opaque rasters: uniform low-chroma corners → corner matte (white frames stay #FFFFFF).
# Else colorpick global average. Transparent corners → trimmed average.
# Usage: detect-field-color.sh [-q] <image>
set -euo pipefail

SCRIPT_DIR="${0:h}"
COLORPICK="$SCRIPT_DIR/colorpick.sh"
MAGICK=/opt/homebrew/bin/magick
[[ -x "$MAGICK" ]] || MAGICK=/usr/local/bin/magick

QUIET=0
[[ "${1:-}" == "-q" ]] && { QUIET=1; shift; }
IMG="${1:?image}"
[[ -f "$IMG" ]] || { echo "#FFFFFF"; exit 0; }
[[ -x "$COLORPICK" ]] || { echo "#FFFFFF"; exit 0; }

emit() {
  if [[ $QUIET -eq 1 ]]; then print -r -- "$1"
  else print -r -- "$1"
  fi
}

corner_alpha() {
  local x=$1 y=$2
  $MAGICK "$IMG" -resize 64x64 -alpha extract -crop "8x8+${x}+${y}" +repage -format '%[fx:mean]' info: 2>/dev/null || echo 0
}

transparent_corners=0
for xy in '0 0' '56 0' '0 56' '56 56'; do
  a=$(corner_alpha ${=xy})
  awk -v a="$a" 'BEGIN{ exit !(a+0 < 0.25) }' && transparent_corners=$((transparent_corners + 1))
done

if (( transparent_corners >= 2 )); then
  TMP="$(mktemp "${TMPDIR:-/tmp}/squircle-field.XXXXXX.png")"
  if $MAGICK "$IMG" -fuzz 2% -trim +repage PNG32:"$TMP" 2>/dev/null && [[ -s "$TMP" ]]; then
    emit "$("$COLORPICK" -q "$TMP" --average)"
    trash "$TMP" 2>/dev/null || rm -f "$TMP"
    exit 0
  fi
  trash "$TMP" 2>/dev/null || rm -f "$TMP"
fi

# Opaque: corner matte when corners agree (wordmarks on white plate — global average lies).
corner_hex_from_image() {
  local w h x2 y2 c1 c2 c3 c4
  w=$($MAGICK "$IMG" -format '%w' info:)
  h=$($MAGICK "$IMG" -format '%h' info:)
  x2=$(( w - 1 ))
  y2=$(( h - 1 ))
  get1() {
    local x=$1 y=$2
    $MAGICK "$IMG" -crop "1x1+${x}+${y}" -alpha on -format '%[hex:u]' info: 2>/dev/null | tr '[:lower:]' '[:upper:]' | sed 's/FF$//' | sed 's/^/0x/'
  }
  c1=$(get1 0 0); c2=$(get1 "$x2" 0); c3=$(get1 0 "$y2"); c4=$(get1 "$x2" "$y2")
  python3 - "$c1" "$c2" "$c3" "$c4" <<'PY'
import sys
def parse(s):
    s = s.strip()
    if s.startswith("0x"):
        s = s[2:]
    if len(s) >= 8:
        s = s[:6]
    elif len(s) == 6:
        pass
    else:
        return None
    return tuple(int(s[i:i+2], 16) for i in (0, 2, 4))

cs = [parse(x) for x in sys.argv[1:5]]
if any(c is None for c in cs):
    sys.exit(1)
tol = 4
for i in range(4):
    for j in range(i + 1, 4):
        if any(abs(cs[i][k] - cs[j][k]) > tol for k in range(3)):
            sys.exit(1)
r = sum(c[0] for c in cs) // 4
g = sum(c[1] for c in cs) // 4
b = sum(c[2] for c in cs) // 4
# Four agreeing corners = plate matte (navy tiles, white wordmarks, brand pinks).
print(f"#{r:02X}{g:02X}{b:02X}")
PY
}

if corner_hex=$(corner_hex_from_image 2>/dev/null) && [[ -n "$corner_hex" ]]; then
  emit "$corner_hex"
  exit 0
fi

emit "$("$COLORPICK" -q "$IMG" --average)"
