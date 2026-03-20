#!/bin/zsh
# squircle.sh - One image in → squircle WebP out. Or: <dir> → batch (parallel over dir, output to webp/).
# Usage: squircle <file> [options]   OR   squircle <directory>
# File: pipeline as below. Directory: GNU Parallel over all files, output to $SQUIRCLE/webp/.
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
typeset -g CLIP_FRAME_TMP CLIP_MASKED_TMP CLIP_DIFF_TMP CLIP_FRAME_FLAT_TMP CLIP_MASKED_FLAT_TMP
CLIP_FRAME_TMP=""; CLIP_MASKED_TMP=""; CLIP_DIFF_TMP=""; CLIP_FRAME_FLAT_TMP=""; CLIP_MASKED_FLAT_TMP=""

cleanup() {
  [[ -n "$MASK_TMP" && -f "$MASK_TMP" ]] && rm -f "$MASK_TMP"
  [[ -n "$TMP_PNG" && -f "$TMP_PNG" ]] && rm -f "$TMP_PNG"
  [[ -n "$TMP_SVG_PNG" && -f "$TMP_SVG_PNG" ]] && rm -f "$TMP_SVG_PNG"
  [[ -n "$TMP_QL_DIR" && -d "$TMP_QL_DIR" ]] && rm -rf "$TMP_QL_DIR"
  [[ -n "$CLIP_FRAME_TMP" && -f "$CLIP_FRAME_TMP" ]] && rm -f "$CLIP_FRAME_TMP"
  [[ -n "$CLIP_MASKED_TMP" && -f "$CLIP_MASKED_TMP" ]] && rm -f "$CLIP_MASKED_TMP"
  [[ -n "$CLIP_DIFF_TMP" && -f "$CLIP_DIFF_TMP" ]] && rm -f "$CLIP_DIFF_TMP"
  [[ -n "$CLIP_FRAME_FLAT_TMP" && -f "$CLIP_FRAME_FLAT_TMP" ]] && rm -f "$CLIP_FRAME_FLAT_TMP"
  [[ -n "$CLIP_MASKED_FLAT_TMP" && -f "$CLIP_MASKED_FLAT_TMP" ]] && rm -f "$CLIP_MASKED_FLAT_TMP"
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
  --out-dir DIR    Output directory (batch mode only). Created if missing.
                   Directory mode is recursive and preserves the input folder structure:
                   <out-dir>/<relative_path_from_input>/<basename>.webp (existing files are skipped).
  --clip-queue     Batch: detect likely edge clipping then rerender with increasing padding until fixed. (default)
  --no-clip-queue  Disable automatic clip detection + rerender in batch mode.
                   Creates marker files: <output>.CLIPPED
                   Queue output path stays the same; only padding changes.
  --clip-keep-markers  Keep .CLIPPED marker files after queue finishes (otherwise deleted; report kept).
  --clip-padding-start N   Initial padding px (default: 100).
  --clip-padding-step  N   Padding increment per iteration (default: 50).
  --clip-padding-max-iter K Max padding iterations (default: 4).
  --clip-threshold X       Clipping threshold (default: 0.05).
  --clip-crop-divisor D   Corner crop size = size/D (default: 11).
  --clip-detect-only        Compute clip markers but do not write WebP.
  --clip-detect             Compute clip markers and write WebP.
  --overwrite               Directory mode: overwrite existing outputs.
  --padding [N]    Center logo with margin. N = padding in px per side (default ~100); omit for default.
  -h, --help       Show this help.

Examples:
  $SCRIPT_NAME icon.png
  $SCRIPT_NAME icon.svg --padding
  $SCRIPT_NAME icon.svg --padding 80
  $SCRIPT_NAME icon.svg --padding 150
  $SCRIPT_NAME icon.icns --bg "#FF0000" --out ./out.webp
  $SCRIPT_NAME /path/to/ph.ico --out webp/ph.webp
  $SCRIPT_NAME ~/Downloads
  $SCRIPT_NAME /path/to/dir

EOF
  exit 0
}

# Check help before parsing
for a in "$@"; do
  case "$a" in -h|--help) show_help ;; esac
done

# --- Router: if first arg is a directory → batch (parallel), then exit ---
if [[ $# -ge 1 && -d "$1" ]]; then
  ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  export SQUIRCLE="${SQUIRCLE:-$ROOT}"
  command -v parallel &>/dev/null || { echo "GNU Parallel required: brew install parallel"; exit 1; }

  typeset -a argv=("$@")
  typeset out_dir=""
  typeset clip_queue=1
  typeset clip_padding_start=100
  typeset clip_padding_step=50
  typeset clip_padding_max_iter=4
  typeset clip_threshold="0.05"
  typeset clip_crop_divisor=11
  typeset overwrite=0
  typeset clip_keep_markers=0

  # Extract --out-dir (supports `--out-dir X` and `--out-dir=X`)
  for ((idx=1; idx<=$#argv; idx++)); do
    a="${argv[$idx]}"
    case "$a" in
      --out-dir=*) out_dir="${a#--out-dir=}" ;;
      --out-dir)
        if (( idx < $#argv )); then out_dir="${argv[$((idx+1))]}"; fi
        ;;
    esac
  done

  # Extract clip-queue params (supports `--flag value` and `--flag=value`)
  for ((idx=1; idx<=$#argv; idx++)); do
    a="${argv[$idx]}"
    case "$a" in
      --clip-queue) clip_queue=1 ;;
      --no-clip-queue) clip_queue=0 ;;
      --clip-padding-start=*) clip_padding_start="${a#--clip-padding-start=}" ;;
      --clip-padding-start)
        if (( idx < $#argv )); then clip_padding_start="${argv[$((idx+1))]}"; fi ;;
      --clip-padding-step=*) clip_padding_step="${a#--clip-padding-step=}" ;;
      --clip-padding-step)
        if (( idx < $#argv )); then clip_padding_step="${argv[$((idx+1))]}"; fi ;;
      --clip-padding-max-iter=*) clip_padding_max_iter="${a#--clip-padding-max-iter=}" ;;
      --clip-padding-max-iter)
        if (( idx < $#argv )); then clip_padding_max_iter="${argv[$((idx+1))]}"; fi ;;
      --clip-threshold=*) clip_threshold="${a#--clip-threshold=}" ;;
      --clip-threshold)
        if (( idx < $#argv )); then clip_threshold="${argv[$((idx+1))]}"; fi ;;
      --clip-crop-divisor=*) clip_crop_divisor="${a#--clip-crop-divisor=}" ;;
      --clip-crop-divisor)
        if (( idx < $#argv )); then clip_crop_divisor="${argv[$((idx+1))]}"; fi ;;
      --overwrite) overwrite=1 ;;
      --clip-keep-markers) clip_keep_markers=1 ;;
    esac
  done

  [[ -z "$out_dir" ]] && out_dir="${SQUIRCLE:-$ROOT}/webp"
  [[ -d "$out_dir" ]] || mkdir -p "$out_dir"

  # Forward all args except:
  # - the input directory itself (argv[1])
  # - --out-dir (+ value), --out (+ value), and queue-only flags, since batch output path is controlled by --out-dir
  typeset -a pass_args=()
  typeset skip_next=0
  for ((idx=1; idx<=$#argv; idx++)); do
    (( idx == 1 )) && continue
    if (( skip_next )); then skip_next=0; continue; fi
    a="${argv[$idx]}"
    case "$a" in
      --out-dir) skip_next=1 ;;
      --out-dir=*) : ;;
      --out) skip_next=1 ;;
      --out=*) : ;;
      --overwrite) : ;;
      --clip-queue) : ;;
      --no-clip-queue) : ;;
      --clip-keep-markers) : ;;
      --clip-padding-start) skip_next=1 ;;
      --clip-padding-start=*) : ;;
      --clip-padding-step) skip_next=1 ;;
      --clip-padding-step=*) : ;;
      --clip-padding-max-iter) skip_next=1 ;;
      --clip-padding-max-iter=*) : ;;
      --clip-threshold) skip_next=1 ;;
      --clip-threshold=*) : ;;
      --clip-crop-divisor) skip_next=1 ;;
      --clip-crop-divisor=*) : ;;
      --clip-detect) : ;;
      --clip-detect-only) : ;;
      --padding) skip_next=1 ;;
      --padding=*) : ;;
      *) pass_args+=("$a") ;;
    esac
  done

  typeset -a CLIP_EXTRA_ARGS=()

  # Batch tasks: preserve relative folder structure under --out-dir.
  setopt local_options
  INPUT_DIR="${1%/}"

  typeset -a all_inputs=()
  typeset -a all_outputs=()

  for f in "$INPUT_DIR"/**/*; do
    [[ -f "$f" ]] || continue
    rel="${f#$INPUT_DIR/}"
    out_path="$out_dir/${rel%.*}.webp"
    mkdir -p "${out_path:h}"

    if (( clip_queue == 0 )); then
      # Default batch mode: skip existing outputs unless --overwrite.
      if [[ -f "$out_path" && $overwrite -ne 1 ]]; then
        echo "skip (exists): $out_path" >&2
        continue
      fi
    fi

    all_inputs+=("$f")
    all_outputs+=("$out_path")
  done

  # Helper: run parallel tasks for a selected set of indexes.
  run_parallel_by_indexes() {
    typeset -a idxs=("$@")
    if (( ${#idxs[@]} == 0 )); then return 0; fi

    # Emit input/output pairs for GNU Parallel.
    for k in "${idxs[@]}"; do
      printf '%s\t%s\n' "${all_inputs[$k]}" "${all_outputs[$k]}"
    done | parallel --no-notice -j 0 --colsep '\t' "$SCRIPT_DIR/$SCRIPT_NAME" {1} --out {2} "${CLIP_EXTRA_ARGS[@]}" "${pass_args[@]}"
  }

  # Same as run_parallel_by_indexes, but sequential (debug/robustness mode).
  run_sequential_by_indexes() {
    typeset -a idxs=("$@")
    if (( ${#idxs[@]} == 0 )); then return 0; fi

    for k in "${idxs[@]}"; do
      "$SCRIPT_DIR/$SCRIPT_NAME" "${all_inputs[$k]}" --out "${all_outputs[$k]}" "${CLIP_EXTRA_ARGS[@]}" "${pass_args[@]}"
    done
  }

  if (( clip_queue == 1 )); then
    # Iteration 0: fill-mode detect-only (no --padding), write markers next to outputs.
    typeset -a idxs=()
    for ((i=1; i<=${#all_inputs[@]}; i++)); do idxs+=("$i"); done
    CLIP_EXTRA_ARGS=(--clip-detect --clip-threshold "$clip_threshold" --clip-crop-divisor "$clip_crop_divisor")
    run_sequential_by_indexes "${idxs[@]}"

    # Subsequent iterations: rerender only files whose marker still exists.
    iter=1
    pad="$clip_padding_start"
    while (( iter <= clip_padding_max_iter )); do
      typeset -a rerun_idxs=()
      for ((i=1; i<=${#all_outputs[@]}; i++)); do
        marker="${all_outputs[$i]}.CLIPPED"
        [[ -f "$marker" ]] && rerun_idxs+=("$i")
      done
      (( ${#rerun_idxs[@]} == 0 )) && break

      CLIP_EXTRA_ARGS=(--clip-detect --padding "$pad" --clip-threshold "$clip_threshold" --clip-crop-divisor "$clip_crop_divisor")
      run_sequential_by_indexes "${rerun_idxs[@]}"

      pad=$(( pad + clip_padding_step ))
      iter=$(( iter + 1 ))
    done
  else
    # Normal batch mode: run over all_inputs/all_outputs (already filtered by skip/overwrite).
    typeset -a idxs=()
    for ((i=1; i<=${#all_inputs[@]}; i++)); do idxs+=("$i"); done
    CLIP_EXTRA_ARGS=()
    run_parallel_by_indexes "${idxs[@]}"
  fi

  # Clip markers are debug-only by default.
  # If markers remain after max iterations, write an "unfixed" report
  # and delete the marker files to avoid clutter.
  if (( clip_queue == 1 && clip_keep_markers == 0 )); then
    report="${out_dir}/.clip_queue_unfixed.txt"
    : > "$report"
    for ((i=1; i<=${#all_outputs[@]}; i++)); do
      marker="${all_outputs[$i]}.CLIPPED"
      if [[ -f "$marker" ]]; then
        printf '%s\n' "${all_outputs[$i]}" >> "$report"
        rm -f "$marker"
      fi
    done
  fi

  echo "Done."
  exit 0
fi

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
  typeset -g BG_OVERRIDE ICON_COLOR SIZE OUTPUT INPUT OPAQUE_PADDING PADDING_PX
  typeset -g CLIP_DETECT CLIP_DETECT_ONLY CLIP_THRESHOLD CLIP_CROP_DIVISOR CLIP_MARKER_SUFFIX
  BG_OVERRIDE=(); ICON_COLOR=(); SIZE=(); OUTPUT=(); INPUT=""
  OPAQUE_PADDING=0; PADDING_PX=""
  CLIP_DETECT=0; CLIP_DETECT_ONLY=0; CLIP_THRESHOLD="0.05"; CLIP_CROP_DIVISOR=11; CLIP_MARKER_SUFFIX=".CLIPPED"
  typeset -a args=()
  next=""
  for a in "${save_args[@]}"; do
    if [[ "$next" == "bg" ]]; then BG_OVERRIDE="$a"; next=""; continue; fi
    if [[ "$next" == "icon-color" ]]; then ICON_COLOR="$a"; next=""; continue; fi
    if [[ "$next" == "size" ]]; then SIZE="$a"; next=""; continue; fi
    if [[ "$next" == "out" ]]; then OUTPUT="$a"; next=""; continue; fi
    if [[ "$next" == "clip-threshold" ]]; then CLIP_THRESHOLD="$a"; next=""; continue; fi
    if [[ "$next" == "clip-crop-divisor" ]]; then CLIP_CROP_DIVISOR="$a"; next=""; continue; fi
    if [[ "$next" == "padding" ]]; then
      [[ "$a" == [0-9]* ]] && PADDING_PX="$a"
      next=""
      OPAQUE_PADDING=1
      continue
    fi
    case "$a" in
      --bg) next="bg" ;;
      --icon-color) next="icon-color" ;;
      --size) next="size" ;;
      --out) next="out" ;;
      --padding) next="padding"; OPAQUE_PADDING=1 ;;
      --clip-detect) CLIP_DETECT=1 ;;
      --clip-detect-only) CLIP_DETECT=1; CLIP_DETECT_ONLY=1 ;;
      --clip-threshold) next="clip-threshold" ;;
      --clip-crop-divisor) next="clip-crop-divisor" ;;
      *) args+=("$a") ;;
    esac
  done
  [[ "$next" == "padding" ]] && { OPAQUE_PADDING=1; next=""; }
  [[ ${#args[@]} -lt 1 ]] && { echo "🔴 Usage: $0 <input> [--bg #HEX] [--icon-color #HEX] [--size 1024] [--out path.webp] [--padding [N]] [--clip-detect|--clip-detect-only] [--clip-threshold X] [--clip-crop-divisor D]" >&2; exit 1; }
  INPUT="${args[1]}"
  # Only use args[2] as OUTPUT if it looks like a path (has . or /), not a number
  if [[ -z "$OUTPUT" && -n "${args[2]:-}" && "${args[2]}" != --* ]]; then
    [[ "${args[2]}" == *.* || "${args[2]}" == */* ]] && OUTPUT="${args[2]}"
  fi
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

# Sample average corner background color (downscale + average 4 corners).
# Output: "#RRGGBB"
sample_corner_bg_hex() {
  local img="$1"
  [[ ! -f "$img" ]] && { echo "#FFFFFF"; return 0; }

  get_corner_rgb() {
    local x="$1" y="$2"
    # 64x64 sample; corners are at 0/48 for a 16x16 crop.
    $MAGICK -limit thread 1 "$img" -resize 64x64 -alpha on -background none \
      -crop 16x16+${x}+${y} +repage -scale 1x1! \
      -format "%[fx:round(255*u.r)] %[fx:round(255*u.g)] %[fx:round(255*u.b)]" info: 2>/dev/null
  }

  local c1 c2 c3 c4
  c1="$(get_corner_rgb 0 0)" || c1="255 255 255"
  c2="$(get_corner_rgb 48 0)" || c2="255 255 255"
  c3="$(get_corner_rgb 0 48)" || c3="255 255 255"
  c4="$(get_corner_rgb 48 48)" || c4="255 255 255"

  local avg r g b
  avg="$(printf '%s\n%s\n%s\n%s\n' "$c1" "$c2" "$c3" "$c4" | awk '{r+=$1;g+=$2;b+=$3} END{printf "%d %d %d", int(r/4+0.5), int(g/4+0.5), int(b/4+0.5)}' 2>/dev/null)" || avg="255 255 255"
  r="$(echo "$avg" | awk '{print $1}')"
  g="$(echo "$avg" | awk '{print $2}')"
  b="$(echo "$avg" | awk '{print $3}')"

  # Clamp to 0-255 just in case.
  r=$(( r < 0 ? 0 : (r > 255 ? 255 : r) ))
  g=$(( g < 0 ? 0 : (g > 255 ? 255 : g) ))
  b=$(( b < 0 ? 0 : (b > 255 ? 255 : b) ))
  printf "#%02X%02X%02X\n" "$r" "$g" "$b"
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

# --- Render: OPAQUE fill (trim transparent edges, then scale to fill frame) ---
render_opaque_fill() {
  local raster="$1" mask="$2" output="$3" size="$4"
  $MAGICK -limit thread 1 \
    \( "$raster" -trim +repage -resize "${size}x${size}^" -gravity center -extent "${size}x${size}" \) \
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

# --- Clip detection (opaque fill/padding): corner diff score vs squircle-masked version ---
compute_clip_marker() {
  local raster="$1" mask="$2" size="$3" padding_bg="$4" logo_size="$5"
  local crop_px x y

  crop_px=$(( size / CLIP_CROP_DIVISOR ))
  (( crop_px < 32 )) && crop_px=32
  (( crop_px > 128 )) && crop_px=128
  x=$(( size - crop_px ))
  y=$(( size - crop_px ))

  CLIP_FRAME_TMP="${SCRIPT_DIR}/.clip_frame_$$.png"
  CLIP_MASKED_TMP="${SCRIPT_DIR}/.clip_masked_$$.png"
  CLIP_DIFF_TMP="${SCRIPT_DIR}/.clip_diff_$$.png"
  CLIP_FRAME_FLAT_TMP="${SCRIPT_DIR}/.clip_frame_flat_$$.png"
  CLIP_MASKED_FLAT_TMP="${SCRIPT_DIR}/.clip_masked_flat_$$.png"

  if [[ $OPAQUE_PADDING -eq 1 ]]; then
    # Padding mode unmasked: scaled logo centered with margin background.
    $MAGICK -limit thread 1 \
      \( "$raster" -resize "${logo_size}x${logo_size}^" -gravity center -background "$padding_bg" -extent "${size}x${size}" \) \
      "$CLIP_FRAME_TMP"
  else
    # Fill mode unmasked: trim transparent edges then scale-to-fill the frame.
    $MAGICK -limit thread 1 \
      \( "$raster" -trim +repage -resize "${size}x${size}^" -gravity center -extent "${size}x${size}" \) \
      "$CLIP_FRAME_TMP"
  fi

  # Apply squircle mask (creates transparency outside rounded shape).
  $MAGICK -limit thread 1 "$CLIP_FRAME_TMP" "$mask" -alpha off -compose CopyOpacity -composite "$CLIP_MASKED_TMP"

  # Flatten both against the unmasked frame's corner background color,
  # then compute a corner-only difference score.
  local diff_bg_hex
  diff_bg_hex="$(sample_corner_bg_hex "$CLIP_FRAME_TMP" || echo "#FFFFFF")"
  $MAGICK "$CLIP_FRAME_TMP" -background "$diff_bg_hex" -alpha remove -alpha off "$CLIP_FRAME_FLAT_TMP" >/dev/null 2>&1 || cp "$CLIP_FRAME_TMP" "$CLIP_FRAME_FLAT_TMP"
  $MAGICK "$CLIP_MASKED_TMP" -background "$diff_bg_hex" -alpha remove -alpha off "$CLIP_MASKED_FLAT_TMP" >/dev/null 2>&1 || cp "$CLIP_MASKED_TMP" "$CLIP_MASKED_FLAT_TMP"

  $MAGICK "$CLIP_FRAME_FLAT_TMP" "$CLIP_MASKED_FLAT_TMP" -alpha off -compose difference -composite "$CLIP_DIFF_TMP" >/dev/null 2>&1 || true

  tl=$($MAGICK "$CLIP_DIFF_TMP" -crop ${crop_px}x${crop_px}+0+0 +repage -format "%[fx:mean]" info: 2>/dev/null | tr -d '\n' || echo "")
  tr=$($MAGICK "$CLIP_DIFF_TMP" -crop ${crop_px}x${crop_px}+${x}+0 +repage -format "%[fx:mean]" info: 2>/dev/null | tr -d '\n' || echo "")
  bl=$($MAGICK "$CLIP_DIFF_TMP" -crop ${crop_px}x${crop_px}+0+${y} +repage -format "%[fx:mean]" info: 2>/dev/null | tr -d '\n' || echo "")
  br=$($MAGICK "$CLIP_DIFF_TMP" -crop ${crop_px}x${crop_px}+${x}+${y} +repage -format "%[fx:mean]" info: 2>/dev/null | tr -d '\n' || echo "")

  clip_score=$(awk -v tl="$tl" -v tr="$tr" -v bl="$bl" -v br="$br" 'BEGIN{print (tl+tr+bl+br)/4}' 2>/dev/null || echo "1")
  clipped=$(awk -v s="$clip_score" -v t="$CLIP_THRESHOLD" 'BEGIN{print (s>=t)?1:0}' 2>/dev/null || echo "1")

  marker="${OUTPUT}${CLIP_MARKER_SUFFIX}"
  if [[ "$clipped" == "1" ]]; then
    : > "$marker"
  else
    [[ -f "$marker" ]] && rm -f "$marker"
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
  build_mask "$SIZE" >/dev/null
  local padding_bg="#FFFFFF"
  if (( ${#BG_OVERRIDE[@]} > 0 )); then
    padding_bg="$BG_OVERRIDE[1]"
  fi
  local logo_size
  if [[ -n "$PADDING_PX" && "$PADDING_PX" -ge 0 ]]; then
    logo_size=$(( SIZE - 2 * PADDING_PX ))
    [[ $logo_size -lt 8 ]] && logo_size=8
  else
    logo_size=$(( SIZE * LOGO_RATIO / 1024 ))
    [[ $logo_size -lt 8 ]] && logo_size=8
  fi

  # In OPAQUE+padding mode, default margin color should match the source background.
  if [[ "$BG_HEX" == "OPAQUE" && $OPAQUE_PADDING -eq 1 && "$padding_bg" == "#FFFFFF" ]]; then
    padding_bg="$(sample_corner_bg_hex "$IN_FOR_MAGICK" || echo "#FFFFFF")"
  fi

  # Optional: compute clipping marker before rendering (opaque path only).
  if (( CLIP_DETECT == 1 )); then
    if [[ "$BG_HEX" == "OPAQUE" ]]; then
      compute_clip_marker "$IN_FOR_MAGICK" "$MASK_TMP" "$SIZE" "$padding_bg" "$logo_size" || true
    else
      [[ -n "$OUTPUT" ]] && rm -f "${OUTPUT}${CLIP_MARKER_SUFFIX}" 2>/dev/null || true
    fi
    if (( CLIP_DETECT_ONLY == 1 )); then
      exit 0
    fi
  fi

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
