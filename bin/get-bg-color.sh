#!/bin/zsh
# get-bg-color.sh - Background color from image (edge/corner sampling). Used by squircle.sh.
# Usage: ./get-bg-color.sh <image>   → #RRGGBB or OPAQUE

set -e

MAGICK=/opt/homebrew/bin/magick
[[ -x "$MAGICK" ]] || MAGICK=/usr/local/bin/magick

# Deterministic: single-thread, no internal parallelism
export MAGICK_THREAD_LIMIT=1

[[ -z "$1" || ! -f "$1" ]] && { echo "#FFFFFF"; exit 0; }
INPUT="$1"

# Use first frame for multi-frame (e.g. icns)
IN="$INPUT"
[[ "$INPUT" == *".icns" ]] && IN="${INPUT}[0]"

# Mean alpha of full image: low = mostly transparent = no background
MEAN_ALPHA=$($MAGICK "$IN" -limit thread 1 -resize 64x64 -alpha extract -format "%[fx:mean]" info: 2>/dev/null || echo "0")
if [[ -z "$MEAN_ALPHA" ]]; then
  echo "#FFFFFF"
  exit 0
fi
# Already has background (mostly opaque) → no base layer; pipeline will just mask the image
if $(echo "$MEAN_ALPHA" | awk '{ exit !($1 >= 0.6) }'); then
  echo "OPAQUE"
  exit 0
fi
# Center mostly opaque (e.g. rounded icon with transparent corners) → no base layer
CENTER_ALPHA=$($MAGICK "$IN" -limit thread 1 -resize 64x64 -alpha extract -gravity center -crop 50%x50%+0+0 +repage -format "%[fx:mean]" info: 2>/dev/null || echo "0")
if $(echo "$CENTER_ALPHA" | awk '{ exit !($1 >= 0.7) }'); then
  echo "OPAQUE"
  exit 0
fi

# Sample 4 corners (16x16 blocks)
get_corner() {
  local x=$1 y=$2
  $MAGICK "$IN" -limit thread 1 -resize 64x64 -alpha on -background none \
    -crop 16x16+${x}+${y} +repage -scale 1x1! \
    -format "%[fx:round(255*u.r)] %[fx:round(255*u.g)] %[fx:round(255*u.b)] %[fx:u.a]\n" info: 2>/dev/null
}
C1=$(get_corner 0 0)
C2=$(get_corner 48 0)
C3=$(get_corner 0 48)
C4=$(get_corner 48 48)

# If corners are mostly transparent (avg alpha < 0.35), treat as logo on transparent bg → white
corners_avg_a=$(printf '%s\n' "$C1" "$C2" "$C3" "$C4" | awk '{sum+=$4} END{print sum/4}')
if $(echo "$corners_avg_a" | awk '{ exit !($1 < 0.35) }'); then
  echo "#FFFFFF"
  exit 0
fi

# Average the 4 corners: use only corners with substantial alpha (real background)
sum_r=0 sum_g=0 sum_b=0 count=0
for line in "$C1" "$C2" "$C3" "$C4"; do
  r=$(echo "$line" | awk '{print $1}'); g=$(echo "$line" | awk '{print $2}'); b=$(echo "$line" | awk '{print $3}'); a=$(echo "$line" | awk '{print $4}')
  $(echo "$a" | awk '{ exit !($1 >= 0.2) }') || continue
  sum_r=$(( sum_r + r )); sum_g=$(( sum_g + g )); sum_b=$(( sum_b + b )); count=$(( count + 1 ))
done
if [[ $count -eq 0 ]]; then
  echo "#FFFFFF"
  exit 0
fi
R=$(( sum_r / count )); G=$(( sum_g / count )); B=$(( sum_b / count ))
# Clamp to 0-255
R=$(( R < 0 ? 0 : (R > 255 ? 255 : R) ))
G=$(( G < 0 ? 0 : (G > 255 ? 255 : G) ))
B=$(( B < 0 ? 0 : (B > 255 ? 255 : B) ))
printf "#%02X%02X%02X\n" "$R" "$G" "$B"
exit 0
