#!/bin/zsh
# svg2png - Convert image to PNG by actual file type (file -b), not extension.
# Usage: svg2png <file> [output.png]
# Supports: SVG, JPEG, WebP, PNG (re-encode). Output default: <base>.png

set -e
SCRIPT_DIR="${0:h}"
MAGICK=/opt/homebrew/bin/magick
[[ -x "$MAGICK" ]] || MAGICK=/usr/local/bin/magick
SIPS=/usr/bin/sips
RSVG=/opt/homebrew/bin/rsvg-convert
[[ -x "$RSVG" ]] || RSVG=/usr/local/bin/rsvg-convert

[[ -z "$1" || ! -f "$1" ]] && { echo "Usage: ${0:t} <file> [output.png]" >&2; exit 1; }
INPUT="$1"
OUTPUT="${2:-${INPUT:r}.png}"
[[ -n "${OUTPUT:h}" ]] && mkdir -p "${OUTPUT:h}"

FTYPE=$(file -b "$INPUT")
IS_SVG=0
[[ "$FTYPE" == *"SVG"* ]] || [[ "$FTYPE" == *"Scalable Vector"* ]] && IS_SVG=1
[[ "$FTYPE" == *"XML"* ]] && ( [[ "$INPUT" == *".svg" ]] || [[ "$INPUT" == *".svgz" ]] ) && IS_SVG=1

if [[ $IS_SVG -eq 1 ]]; then
  if [[ -x "$RSVG" ]]; then
    SIZE="${SVG2PNG_SIZE:-1024}"
    "$RSVG" -w "$SIZE" -h "$SIZE" "$INPUT" -o "$OUTPUT"
  elif [[ "$(uname)" == Darwin ]]; then
    TMPD="${TMPDIR:-/tmp}/svg2png_$$.d"
    mkdir -p "$TMPD"
    trap "rm -rf '$TMPD'" EXIT
    qlmanage -t -s "${SVG2PNG_SIZE:-1024}" -o "$TMPD" "$INPUT" || { echo "SVG: install rsvg-convert (brew install librsvg)" >&2; exit 1; }
    mv "$TMPD/${INPUT:t}.png" "$OUTPUT"
  else
    echo "SVG: need rsvg-convert (brew install librsvg)" >&2
    exit 1
  fi
elif [[ "$FTYPE" == *"JPEG"* ]] || [[ "$FTYPE" == *"JFIF"* ]]; then
  "$MAGICK" "$INPUT" "$OUTPUT"
elif [[ "$FTYPE" == *"WebP"* ]] || [[ "$FTYPE" == *"Web/P"* ]]; then
  "$MAGICK" "$INPUT" "$OUTPUT"
elif [[ "$FTYPE" == *"PNG"* ]]; then
  "$MAGICK" "$INPUT" "$OUTPUT"
else
  echo "Unsupported type: $FTYPE" >&2
  exit 1
fi

echo "🟢 $OUTPUT"
