#!/bin/zsh
# squircle.sh - One image in → squircle WebP out. Intended for $CURTOOLS; use alias squircle.
# Usage: squircle <input> [--out path] [--size N] [--bg #HEX] [--icon-color #HEX] [--padding]
#
# Pipeline: parse → normalize input to raster → get background (or OPAQUE) → build mask → render → strip metadata.
# Render paths: OPAQUE fill (scale to fill) | OPAQUE + --padding (centered, margin = --bg or white) | transparent base + logo.
# Scriptify-compliant: ENV load, show_help, trap EXIT/ERR/TERM/INT, logmoji, ensure_dependency, retry for external calls.

set -e
setopt pipefail 2>/dev/null || true

# ---------- Load environment ----------
ENV_FILE="${ENV_FILE:-$HOME/scripts/.env}"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null || true

# --- Constants & paths ---
SCRIPT_DIR="${0:h}"
SCRIPT_NAME="${0:t}"
MAGICK=/opt/homebrew/bin/magick
[[ -x "$MAGICK" ]] || MAGICK=/usr/local/bin/magick
SIPS=/usr/bin/sips
export MAGICK_THREAD_LIMIT=1

MASK_FILE="${SCRIPT_DIR}/mask.png"
DEFAULT_SIZE=1024
LOGO_RATIO=824   # 824/1024 = logo size when using --padding (inset from edges)
WEBP_QUALITY=95
WEBP_METHOD=4
RETRY_ATTEMPTS=3
RETRY_SLEEP=1

# Temp paths (cleaned in trap)
typeset -g MASK_TMP TMP_PNG TMP_SVG_PNG TMP_QL_DIR
MASK_TMP=""; TMP_PNG=""; TMP_SVG_PNG=""; TMP_QL_DIR=""

cleanup() {
  [[ -n "$MASK_TMP" && -f "$MASK_TMP" ]] && rm -f "$MASK_TMP"
  [[ -n "$TMP_PNG" && -f "$TMP_PNG" ]] && rm -f "$TMP_PNG"
  [[ -n "$TMP_SVG_PNG" && -f "$TMP_SVG_PNG" ]] && rm -f "$TMP_SVG_PNG"
  [[ -n "$TMP_QL_DIR" && -d "$TMP_QL_DIR" ]] && rm -rf "$TMP_QL_DIR"
}
trap 'cleanup; exit' EXIT
trap 'cleanup; exit 1' ERR
trap cleanup SIGTERM SIGINT

# --- Help (scriptify requirement) ---
show_help() {
  cat << EOF
Usage: $SCRIPT_NAME <input> [options] [--out path.webp]

  One image in → squircle WebP out (1024×1024 by default).

Options:
  --bg #HEX        Background color (e.g. #FFFFFF). With --padding, margin color.
  --icon-color #   Recolor logo (transparent-background path only).
  --size N         Output size (default: 1024).
  --out path.webp  Output path. Default: \$SQUIRCLE/webp/<name>.webp or same dir as input.
  --padding        Center logo with margin (SVGs/edge-to-edge). Default: fill (scale to fill frame).

  -h, --help       Show this help.

Examples:
  $SCRIPT_NAME icon.png
  $SCRIPT_NAME icon.svg --padding
  $SCRIPT_NAME icon.icns --bg "#FF0000" --out ./out.webp
  $SCRIPT_NAME /path/to/ph.ico --out webp/ph.webp

EOF
  exit 0
}

# Check help before parsing
for a in "$@"; do
  case "$a" in -h|--help) show_help ;; esac
done

# --- Ensure ImageMagick (scriptify: auto-install or clear error) ---
ensure_magick() {
  if [[ -x "$MAGICK" ]]; then return 0; fi
  if command -v brew &>/dev/null; then
    echo "🟡 ImageMagick not found. Installing via brew..." >&2
    brew install imagemagick 2>/dev/null || true
    MAGICK=/opt/homebrew/bin/magick
    [[ -x "$MAGICK" ]] || MAGICK=/usr/local/bin/magick
  fi
  if [[ ! -x "$MAGICK" ]]; then
    echo "🔴 ImageMagick (magick) required. Install: brew install imagemagick" >&2
    exit 1
  fi
}

# --- Retry external command (scriptify: retry for external calls) ---
retry_run() {
  local n=$RETRY_ATTEMPTS
  while (( n > 0 )); do
    if "$@" 2>/dev/null; then return 0; fi
    n=$(( n - 1 ))
    [[ $n -gt 0 ]] && sleep $RETRY_SLEEP
  done
  return 1
}

# --- Argument parsing ---
parse_args() {
  typeset -a save_args=("$@")
  typeset -g BG_OVERRIDE ICON_COLOR SIZE OUTPUT INPUT OPAQUE_PADDING
  BG_OVERRIDE=(); ICON_COLOR=(); SIZE=(); OUTPUT=(); OPAQUE_PADDING=0
  typeset -a args=()
  next=""
  for a in "${save_args[@]}"; do
    if [[ "$next" == "bg" ]]; then BG_OVERRIDE="$a"; next=""; continue; fi
    if [[ "$next" == "icon-color" ]]; then ICON_COLOR="$a"; next=""; continue; fi
    if [[ "$next" == "size" ]]; then SIZE="$a"; next=""; continue; fi
    if [[ "$next" == "out" ]]; then OUTPUT="$a"; next=""; continue; fi
    case "$a" in
      --bg) next="bg" ;;
      --icon-color) next="icon-color" ;;
      --size) next="size" ;;
      --out) next="out" ;;
      --padding) OPAQUE_PADDING=1 ;;
      *) args+=("$a") ;;
    esac
  done
  [[ ${#args[@]} -lt 1 ]] && { echo "🔴 Usage: $0 <input> [--bg #HEX] [--icon-color #HEX] [--size 1024] [--out path.webp] [--padding]" >&2; exit 1; }
  INPUT="${args[1]}"
  [[ -z "$OUTPUT" && -n "${args[2]:-}" && "${args[2]}" != --* ]] && OUTPUT="${args[2]}"
  [[ -z "$SIZE" && -n "${args[3]:-}" && "${args[3]}" != --* ]] && SIZE="${args[3]}"
  [[ ! -f "$INPUT" ]] && { echo "🔴 Not a file: $INPUT" >&2; exit 1; }
  : "${SIZE:=$DEFAULT_SIZE}"
  if [[ -z "$OUTPUT" ]]; then
  if [[ -n "${SQUIRCLE:-}" ]]; then
      mkdir -p "$SQUIRCLE/webp"
      OUTPUT="$SQUIRCLE/webp/${INPUT:t:r}.webp"
    else
      OUTPUT="${INPUT:r}.webp"
    fi
  fi
}

# --- Input normalization: produce a raster path ImageMagick can read ---
# Handles: .icns (sips), .ico/.cur (magick first frame), .svg/.svgz (rsvg-convert or qlmanage). Other formats passed through.
# Sets globals: IN_FOR_MAGICK, and optionally TMP_PNG, TMP_SVG_PNG, TMP_QL_DIR (for cleanup).
normalize_input() {
  local raw="$1" size="${2:-$DEFAULT_SIZE}"
  typeset -g IN_FOR_MAGICK TMP_PNG TMP_SVG_PNG TMP_QL_DIR
  IN_FOR_MAGICK="$raw"
  # .icns → PNG (macOS)
  if [[ "$(uname)" == Darwin ]] && [[ "$raw" == *".icns" ]]; then
    TMP_PNG="${SCRIPT_DIR}/.squircle_tmp_$$.png"
    retry_run $SIPS -s format png "$raw" --out "$TMP_PNG" && IN_FOR_MAGICK="$TMP_PNG"
  fi
  # .ico / .cur → first frame to PNG (multi-resolution; use [0])
  if [[ "$raw" == *".ico" ]] || [[ "$raw" == *".cur" ]]; then
    TMP_PNG="${SCRIPT_DIR}/.squircle_tmp_$$.png"
    retry_run $MAGICK "${raw}[0]" -resize "${size}x${size}" "$TMP_PNG" && IN_FOR_MAGICK="$TMP_PNG"
  fi
  # .svg / .svgz → PNG (rsvg-convert or macOS Quick Look)
  if [[ "$raw" == *".svg" ]] || [[ "$raw" == *".svgz" ]]; then
    local rsvg=/opt/homebrew/bin/rsvg-convert
    [[ -x "$rsvg" ]] || rsvg=/usr/local/bin/rsvg-convert
    if [[ -x "$rsvg" ]]; then
      TMP_SVG_PNG="${SCRIPT_DIR}/.squircle_svg_$$.png"
      retry_run $rsvg -w "$size" -h "$size" "$raw" -o "$TMP_SVG_PNG" && IN_FOR_MAGICK="$TMP_SVG_PNG"
    fi
    if [[ "$(uname)" == Darwin ]] && { [[ -z "$IN_FOR_MAGICK" ]] || [[ "$IN_FOR_MAGICK" == "$raw" ]]; }; then
      TMP_QL_DIR="${TMPDIR:-/tmp}/squircle_svg_$$.d"
      mkdir -p "$TMP_QL_DIR"
      if retry_run qlmanage -t -s "$size" -o "$TMP_QL_DIR" "$raw"; then
        local ql_png="${TMP_QL_DIR}/${raw:t}.png"
        [[ -f "$ql_png" ]] && IN_FOR_MAGICK="$ql_png"
      fi
    fi
    if [[ -z "$IN_FOR_MAGICK" ]] || [[ "$IN_FOR_MAGICK" == "$raw" ]]; then
      echo "🔴 SVG: install rsvg-convert (brew install librsvg) or use a .png/.webp source" >&2
      exit 1
    fi
  fi
}

# --- Background: explicit --bg or get-bg-color.sh (returns #HEX or "OPAQUE" for mostly-opaque images) ---
get_background() {
  local raster="$1"
  if [[ -n "$BG_OVERRIDE" ]]; then
    echo "$BG_OVERRIDE"
    return
  fi
  local bg="#FFFFFF"
  if [[ -x "$SCRIPT_DIR/get-bg-color.sh" ]]; then
    bg=$("$SCRIPT_DIR/get-bg-color.sh" "$raster" 2>/dev/null) || true
    [[ -z "$bg" || "$bg" == "NEXT" ]] && bg="#FFFFFF"
  fi
  echo "$bg"
}

# --- Mask: IconSur mask.png or round-rect fallback ---
build_mask() {
  local size="$1"
  MASK_TMP="${SCRIPT_DIR}/.mask_$$.png"
  if [[ -f "$MASK_FILE" ]]; then
    $MAGICK -limit thread 1 "$MASK_FILE" -resize "${size}x${size}" -alpha extract -threshold 50% "$MASK_TMP"
  else
    local r=$(( size / 4 )) x2=$(( size - 1 ))
    $MAGICK -limit thread 1 -size "${size}x${size}" xc:black -fill white -draw "roundRectangle 0,0 ${x2},${x2} ${r},${r}" -alpha extract -threshold 50% "$MASK_TMP"
  fi
  echo "$MASK_TMP"
}

# --- Render: OPAQUE fill (scale to fill frame) ---
render_opaque_fill() {
  local raster="$1" mask="$2" output="$3" size="$4"
  $MAGICK -limit thread 1 \
    \( "$raster" -resize "${size}x${size}^" -gravity center -extent "${size}x${size}" \) \
    "$mask" -alpha off -compose CopyOpacity -composite \
    -define webp:method=$WEBP_METHOD -quality $WEBP_QUALITY "$output"
}

# --- Render: OPAQUE with padding (scale to LOGO_SIZE, center, margin color) ---
render_opaque_padding() {
  local raster="$1" mask="$2" output="$3" size="$4" margin_bg="$5" logo_size="$6"
  $MAGICK -limit thread 1 \
    \( "$raster" -resize "${logo_size}x${logo_size}^" -gravity center -background "$margin_bg" -extent "${size}x${size}" \) \
    "$mask" -alpha off -compose CopyOpacity -composite \
    -define webp:method=$WEBP_METHOD -quality $WEBP_QUALITY "$output"
}

# --- Render: base layer + logo for transparent-background sources; optional icon_color recols logo ---
render_with_base() {
  local raster="$1" mask="$2" output="$3" size="$4" bg_hex="$5" icon_color="${6:-}"
  local logo_size="$7"
  if [[ -n "$icon_color" ]]; then
    $MAGICK -limit thread 1 \
      \( -size "${size}x${size}" xc:"$bg_hex" \) -write mpr:base +delete \
      \( "$raster" -resize "${logo_size}x${logo_size}^" -gravity center -background none -extent "${size}x${size}" -alpha extract -negate -write mpr:amask +delete -size "${size}x${size}" xc:"$icon_color" mpr:amask -alpha off -compose CopyOpacity -composite \) -write mpr:logo +delete \
      mpr:base mpr:logo -compose Over -composite \
      "$mask" -alpha off -compose CopyOpacity -composite \
      -define webp:method=$WEBP_METHOD -quality $WEBP_QUALITY "$output"
  else
    $MAGICK -limit thread 1 \
      \( -size "${size}x${size}" xc:"$bg_hex" \) -write mpr:base +delete \
      \( "$raster" -resize "${logo_size}x${logo_size}^" -gravity center -background none -extent "${size}x${size}" \) -write mpr:logo +delete \
      mpr:base mpr:logo -compose Over -composite \
      "$mask" -alpha off -compose CopyOpacity -composite \
      -define webp:method=$WEBP_METHOD -quality $WEBP_QUALITY "$output"
  fi
}

# --- Strip metadata (repo standard) ---
strip_metadata() {
  exiftool -all= -overwrite_original -q -q "$1" 2>/dev/null || true
  xattr -c "$1" 2>/dev/null || true
}

# --- Main: parse → normalize → background → mask → one of three render paths → strip metadata ---
main() {
  parse_args "$@"
  ensure_magick
  normalize_input "$INPUT" "$SIZE"
  typeset -g BG_HEX
  BG_HEX=$(get_background "$IN_FOR_MAGICK")
  local logo_size=$(( SIZE * LOGO_RATIO / 1024 ))
  [[ $logo_size -lt 8 ]] && logo_size=8
  build_mask "$SIZE" >/dev/null
  local padding_bg="${BG_OVERRIDE:-#FFFFFF}"   # margin color when --padding; --bg or white

  if [[ "$BG_HEX" == "OPAQUE" ]]; then
    if [[ $OPAQUE_PADDING -eq 1 ]]; then
      render_opaque_padding "$IN_FOR_MAGICK" "$MASK_TMP" "$OUTPUT" "$SIZE" "$padding_bg" "$logo_size"
    else
      render_opaque_fill "$IN_FOR_MAGICK" "$MASK_TMP" "$OUTPUT" "$SIZE"
    fi
  else
    render_with_base "$IN_FOR_MAGICK" "$MASK_TMP" "$OUTPUT" "$SIZE" "$BG_HEX" "$ICON_COLOR" "$logo_size"
  fi

  strip_metadata "$OUTPUT"
  if [[ "$BG_HEX" == "OPAQUE" ]]; then
    echo "🟢 $OUTPUT (${SIZE}×${SIZE}, mode: fill — transparent outside squircle)"
  else
    echo "🟢 $OUTPUT (${SIZE}×${SIZE}, bg ${BG_HEX})"
  fi
}

main "$@"
