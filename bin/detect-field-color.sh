#!/usr/bin/env zsh
# detect-field-color — background / matte hex for squircle margins (colorpick SSOT).
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

corner_alpha() {
  local x=$1 y=$2
  $MAGICK "$IMG" -resize 64x64 -alpha extract -crop "8x8+${x}+${y}" +repage -format '%[fx:mean]' info: 2>/dev/null || echo 0
}

# Sticker on large canvas: trim then average (colorpick).
transparent_corners=0
for xy in '0 0' '56 0' '0 56' '56 56'; do
  a=$(corner_alpha ${=xy})
  awk -v a="$a" 'BEGIN{ exit !(a+0 < 0.25) }' && transparent_corners=$((transparent_corners + 1))
done

TMP=""
if (( transparent_corners >= 2 )); then
  TMP="$(mktemp "${TMPDIR:-/tmp}/squircle-field.XXXXXX.png")"
  if $MAGICK "$IMG" -fuzz 2% -trim +repage PNG32:"$TMP" 2>/dev/null && [[ -s "$TMP" ]]; then
    if [[ $QUIET -eq 1 ]]; then
      "$COLORPICK" -q "$TMP" --average
    else
      "$COLORPICK" "$TMP" --average
    fi
    trash "$TMP" 2>/dev/null || rm -f "$TMP"
    exit 0
  fi
  [[ -n "$TMP" ]] && trash "$TMP" 2>/dev/null || rm -f "$TMP"
fi

# Opaque / flat field: corner pixels via colorpick (not broken resize average).
read -r W H <<<"$($MAGICK "$IMG" -format '%w %h' info:)"
typeset -a hexes=()
for xy in "0 0" "$((W-1)) 0" "0 $((H-1))" "$((W-1)) $((H-1))"; do
  h=$("$COLORPICK" -q "$IMG" ${=xy} 2>/dev/null) || continue
  [[ -n "$h" ]] && hexes+=("${h:l}")
done

if (( ${#hexes[@]} == 0 )); then
  [[ $QUIET -eq 1 ]] && echo "#FFFFFF" || "$COLORPICK" "$IMG" --average
  exit 0
fi

# Average RGB of corner samples.
python3 -c '
import sys
hs = [h.strip().lstrip("#") for h in sys.argv[1:] if h.strip()]
if not hs:
    print("#FFFFFF"); sys.exit(0)
rs=gs=bs=0
for h in hs:
    if len(h)!=6: continue
    rs+=int(h[0:2],16); gs+=int(h[2:4],16); bs+=int(h[4:6],16)
n=len(hs)
print(f"#{(rs//n):02X}{(gs//n):02X}{(bs//n):02X}")
' "${hexes[@]}"
