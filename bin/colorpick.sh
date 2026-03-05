#!/usr/bin/env zsh
# colorpick - CLI color dropper: sample pixel(s) or dominant palette from an image → hex.
# Usage: colorpick <image> [x y]           → hex at (x,y); no coords = center pixel
#        colorpick <image> --palette [N]  → N dominant colors (default 8)
#        colorpick <image> --average       → single average color
# Deps: ImageMagick (magick)

set -e

MAGICK=/opt/homebrew/bin/magick
[[ -x "$MAGICK" ]] || MAGICK=/usr/local/bin/magick

# Print a color swatch (round bullet in 24-bit color) + hex in ALL CAPS
swatch_hex() {
  local hex="${1#\#}"
  local r=$(( 0x${hex:0:2} ))
  local g=$(( 0x${hex:2:2} ))
  local b=$(( 0x${hex:4:2} ))
  printf '\033[38;2;%d;%d;%dm●\033[0m #%s\n' "$r" "$g" "$b" "${(U)hex}"
}

usage() {
  echo "Usage: colorpick [-q] <image> [x y]           # hex at (x,y); omit = center" >&2
  echo "       colorpick [-q] <image> --palette [N]    # N dominant colors (default 8)" >&2
  echo "       colorpick [-q] <image> --average        # one average color" >&2
  echo "       -q  no swatch, hex only" >&2
  exit 1
}

[[ $# -lt 1 ]] && usage
QUIET=0
[[ "${1:-}" == "-q" || "${1:-}" == "--quiet" ]] && { QUIET=1; shift }
[[ $# -lt 1 ]] && usage
IMG="$1"
[[ ! -f "$IMG" ]] && { echo "colorpick: not a file: $IMG" >&2; exit 1; }
SHOW_SWATCH=0
[[ $QUIET -eq 0 && -t 1 ]] && SHOW_SWATCH=1

# Image size for center default
DIMS=$($MAGICK "$IMG" -format "%w %h" info: 2>/dev/null) || { echo "colorpick: could not read image" >&2; exit 1; }
W=${DIMS%% *}
H=${DIMS##* }

case "${2:-}" in
  --average)
    RAW=$($MAGICK "$IMG" -resize 1x1\! -format "#%[hex:u.p{0,0}]" info: 2>/dev/null)
    HEX="#${RAW:1:6}"
    if [[ $SHOW_SWATCH -eq 1 ]]; then swatch_hex "$HEX"; else echo "$HEX"; fi
    exit 0
    ;;
  --palette)
    N="${3:-8}"
    $MAGICK "$IMG" -resize 200x200 -colors "$N" -unique-colors txt:- 2>/dev/null | while read -r line; do
      if [[ "$line" =~ '#'([0-9A-Fa-f]{6}) ]]; then
        HEX="#${match[1]:l}"
        if [[ $SHOW_SWATCH -eq 1 ]]; then swatch_hex "$HEX"; else echo "$HEX"; fi
      fi
    done
    exit 0
    ;;
esac

# Sample at (x,y)
if [[ -n "$2" && -n "$3" ]]; then
  X="$2"
  Y="$3"
else
  X=$(( W / 2 ))
  Y=$(( H / 2 ))
fi

# 1x1 crop at (X,Y), output hex (#RRGGBB) + swatch if TTY
RAW=$($MAGICK "$IMG" -crop "1x1+${X}+${Y}" +repage -format "#%[hex:u.p{0,0}]" info: 2>/dev/null)
HEX="#${RAW:1:6}"
if [[ $SHOW_SWATCH -eq 1 ]]; then swatch_hex "$HEX"; else echo "$HEX"; fi
