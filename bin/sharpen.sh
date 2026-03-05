#!/bin/zsh
# sharpen.sh - Sharpen an image. Usage: sharpen <input> [output]
# If no output given, writes <base>_sharpened.<ext>

set -e
MAGICK=/opt/homebrew/bin/magick
[[ -x "$MAGICK" ]] || MAGICK=/usr/local/bin/magick

[[ -z "$1" || ! -f "$1" ]] && { echo "Usage: ${0:t} <image> [output]" >&2; exit 1; }
INPUT="$1"
OUTPUT="${2:-${INPUT:r}_sharpened.${INPUT:e}}"
# Default strength: 0x1.0 (radius 0 = auto, sigma 1.0). Increase sigma for stronger.
SIGMA="${SHARPEN_SIGMA:-1.0}"
"$MAGICK" "$INPUT" -sharpen "0x${SIGMA}" "$OUTPUT"
echo "🟢 $OUTPUT"
