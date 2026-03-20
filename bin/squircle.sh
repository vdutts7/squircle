#!/bin/zsh
# =============================================================================
# SPEC: squircle.sh — raster input → WebP composited with squircle alpha; transparent outside mask.
# All tunables live in CONFIG below (no .env / no SQUIRCLE / no SQUIRCLE_PARALLEL_J). CLI overrides where listed.
# =============================================================================
#
# ENTRY_MODES:
#   file_mode: argv[1] is regular file → parse_args → main → exit (no parallel).
#   dir_mode:  argv[1] is directory → router → GNU Parallel children → exit 0 after "Done.".
#
# REPO_ROOT: parent of bin/ (directory containing this script’s bin/). Default --out and batch --out-dir use REPO_ROOT/webp/.
#
# INTERFACE (CLI overrides; defaults from CONFIG):
#   --size N                    output square size (CONFIG: DEFAULT_SIZE).
#   --out PATH                  WebP path (default REPO_ROOT/webp/<input_basename>.webp).
#   --out-dir DIR               batch only; default REPO_ROOT/webp if omitted.
#   --overwrite                 batch + --no-clip-queue: replace existing outputs (see SKIP_RULES).
#   --parallel-j ARG            batch only; GNU Parallel -j (default CONFIG: PARALLEL_J). E.g. 100%, 125%, 200%, 0.
#   --bg / --icon-color / --padding  per-run logo path (unchanged).
#   --clip-detect / --no-clip-detect / --clip-detect-only / clip thresholds & --clip-padding-*  opaque clip pipeline.
#   CONFIG DEFAULT_CLIP_DETECT: when 1, clip-detect is on unless --no-clip-detect (single-file + batch --no-clip-queue inject).
#   --clip-queue / --no-clip-queue / --clip-queue-sequential / --clip-keep-markers  batch routing.
#
# CONFIG (authoritative numbers — see block after SCRIPT_DIR):
#   REPO_ROOT PARALLEL_J SQUIRCLE_TMP_PARENT DEFAULT_SIZE LOGO_RATIO WEBP_* RETRY_* 
#   DEFAULT_CLIP_DETECT CLIP_PADDING_START STEP MAX_ITER THRESHOLD CROP_DIVISOR CLIP_MARKER_SUFFIX MAGICK SIPS MASK_FILE
#   PLATE_FX PLATE_FX_GRADIENT PLATE_FX_DROP_SHADOW — optional post-render polish (see CONFIG block).
#   Ephemeral: SQUIRCLE_TMPBASE="${SQUIRCLE_TMP_PARENT}/squircle_$$" (+ .jobs.tsv, .ql.d); never under SCRIPT_DIR.
#
# PIPELINE_ORDER (main):
#   parse_args → mkdir -p "${OUTPUT:h}" (file_mode) → ensure_magick → normalize_input → BG_HEX=get_background(IN_FOR_MAGICK) → build_mask(SIZE)
#   → compute padding_bg logo_size → [CLIP_DETECT opaque: compute_clip_marker]
#   → [render branch] → [PLATE_FX: apply_plate_fx] → strip_metadata(OUTPUT) → stdout status line.
#
# NORMALIZE_INPUT (input extension):
#   .icns+Darwin → sips → TMP_PNG
#   .ico/.cur     → magick "raw[0]" resize → TMP_PNG
#   .svg/.svgz    → rsvg-convert (-w/-h SIZE) else qlmanage -t -s SIZE → TMP_* ; failure → exit 1
#   else          → IN_FOR_MAGICK=raw path
#
# BACKGROUND_CLASS:
#   get_background: if BG_OVERRIDE set → echo it; else get-bg-color.sh → #HEX | OPAQUE | NEXT→#FFFFFF
#   BG_HEX==OPAQUE → render_opaque_* ; else render_with_base(BG_HEX).
#
# RENDER_OPAQUE_FILL:
#   magick: (raster -trim +repage -resize SxS^ -gravity center -extent SxS) + mask CopyOpacity → WebP.
#
# RENDER_OPAQUE_PADDING:
#   logo_size=max(8, SIZE-2*PADDING_PX) when PADDING_PX set; else ratio branch above.
#   magick: (raster -resize ${logo_size}x${logo_size}^ -gravity center -background margin -extent SxS) + mask → WebP.
#   margin: padding_bg; if OPAQUE_PADDING && default #FFFFFF → sample_corner_bg_hex(IN_FOR_MAGICK).
#
# RENDER_TRANSPARENT (BG_HEX not OPAQUE):
#   xc:bg + logo scaled to logo_size extent center; optional icon_color alpha trick; mask CopyOpacity → WebP.
#
# CLIP_DETECT_ALGORITHM (opaque only; compute_clip_marker):
#   Build CLIP_FRAME_TMP = unmasked square frame (fill: trim+resize^+extent; padding: resize^+extent with margin).
#   CLIP_MASKED_TMP = CLIP_FRAME_TMP composed with mask alpha CopyOpacity.
#   diff_bg_hex = sample_corner_bg_hex(CLIP_FRAME_TMP)   # avoids false unclipped on white icons vs hardcoded white.
#   Flatten frame and masked to diff_bg_hex (alpha remove); difference composite → CLIP_DIFF_TMP.
#   crop_px = clamp(SIZE/CLIP_CROP_DIVISOR, 32, 128); x=y=SIZE-crop_px.
#   clip_score = mean(tl,tr,bl,br) of %[fx:mean] on each crop of CLIP_DIFF_TMP.
#   clipped = (clip_score >= CLIP_THRESHOLD) ? 1 : 0.
#   marker path = "${OUTPUT}${CLIP_MARKER_SUFFIX}"; clipped → : > marker ; else rm -f marker.
#
# MITIGATION (mitigate_opaque_clipping; invoked when CLIP_DETECT && OPAQUE && marker present before/instead of bad render):
#   Regresses prior bug: single-file --clip-detect used to write .CLIPPED but still output fill-only WebP.
#   Loop iter in 0..CLIP_PADDING_MAX_ITER-1:
#     pad = start_pad + iter*CLIP_PADDING_STEP ; start_pad = CLIP_PADDING_START (fill path)
#           or PADDING_PX+CLIP_PADDING_STEP (explicit --padding path still clipped).
#     Set OPAQUE_PADDING=1 PADDING_PX=pad; recompute logo_size margin; compute_clip_marker; render_opaque_padding.
#     Break if marker absent.
#   If still clipped after loop: marker remains; batch post-pass records OUTPUT in out_dir/.clip_queue_unfixed.txt.
#
# CLIP_DETECT branch summary (opaque):
#   Initial compute uses fill-mode geometry for marker only. !marker → always minimum inset (CLIP_PADDING_START), never render_opaque_fill.
#   marker → mitigate loop from CLIP_PADDING_START (no fill-only WebP when --clip-detect).
#   Without --clip-detect, opaque+!user_padding still uses render_opaque_fill as before.
#
# BATCH_ROUTER (argv[1] is directory):
#   Preconditions: command -v parallel. parallel_jobs=CONFIG.PARALLEL_J; CLI --parallel-j overrides.
#   REPO_ROOT from CONFIG (parent of bin/).
#   Enumerate: for f in "$INPUT_DIR"/**/* ; [[ -f "$f" ]] → pairs (input, output).
#   output_path = "${out_dir}/${rel_without_input_prefix%.*}.webp"; mkdir -p "${out_path:h}".
#   Arrays all_inputs/all_outputs: zsh 1-based indices in run_*_by_indexes loops.
#   SKIP_RULES:
#     clip_queue==1 → never continue/skip on existing output (full tree reprocessed each run).
#     clip_queue==0 → skip if [[ -f out_path && overwrite -ne 1 ]].
#   batch_clip_inject: DEFAULT_CLIP_DETECT==1 and argv has no --no-clip-detect → children get CLIP_EXTRA_ARGS clip tuple; else CLIP_EXTRA_ARGS=().
#   clip_queue==1 → run_parallel_by_indexes all (or run_sequential_by_indexes if --clip-queue-sequential); CLIP_EXTRA_ARGS = clip tuple when batch_clip_inject else ().
#   clip_queue==0 → same CLIP_EXTRA_ARGS rule; parallel -j "$parallel_jobs"; skip existing unless --overwrite.
#   Child argv: "$SCRIPT_DIR/$SCRIPT_NAME" INPUT --out OUTPUT $CLIP_EXTRA_ARGS $pass_args
#   pass_args: strips argv[1], --out-dir*, --out*, --overwrite, all clip-queue tuning flags, --padding* (batch output path fixed).
#   Post clip_queue==1 && batch_clip_inject && !clip_keep_markers: truncate out_dir/.clip_queue_unfixed.txt; for each planned OUTPUT append line if
#     "${OUTPUT}${CLIP_MARKER_SUFFIX}" exists then rm marker (report lists unfixed paths).
#
# OUTPUT_ARTIFACTS:
#   Primary: OUTPUT (path to .webp).
#   Side: "${OUTPUT}${CLIP_MARKER_SUFFIX}" (empty file; presence means heuristic still clipped after mitigation); batch cleanup removes unless
#     --clip-keep-markers.
#   Batch report: "${out_dir}/.clip_queue_unfixed.txt" (one OUTPUT path per line; empty file if none unfixed).
#
# STRIP_METADATA: exiftool -all= -overwrite_original; xattr -c; both errors ignored.
#
# NON_GOALS / HARD_LIMITS:
#   interpreter=zsh only (${0:h}, arrays, glob **, parse_args indexing).
#   dir_mode hard-depends on GNU parallel binary even when clip_queue sequential.
#   clip metric = corner mean of |frame−masked| post-flatten; not geometric stroke bbox; false+/false− possible.
#   mitigation capped at CLIP_PADDING_MAX_ITER; no unbounded padding search.
#   no file locking; concurrent writers same OUTPUT undefined behavior.
#   transparent BG path: no mitigate_opaque_clipping; CLIP_DETECT clears marker for non-opaque.
#   SVG pixel identity varies by rsvg-convert vs qlmanage.
#   Batch + GNU Parallel: Ctrl+Z suspends the job (zsh: suspended) and leaves a mess. Rapid repeated Ctrl+C can exceed
#     parallel's pending-signal cap (~120) → "Maximal count of pending signals exceeded". Use one Ctrl+C and wait; if stuck,
#     `killall parallel` (kills all parallel on machine — use only if you know it's safe).
#
# =============================================================================

set -e
setopt pipefail 2>/dev/null || true

SCRIPT_DIR="${0:h}"
SCRIPT_NAME="${0:t}"

# =============================================================================
# CONFIG — single edit block (no env vars for squircle behavior). ImageMagick: -limit thread 1 on every magick call.
# =============================================================================
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SQUIRCLE_TMP_PARENT=/tmp
PARALLEL_J=100%
CLIP_PADDING_START=100
CLIP_PADDING_STEP=50
CLIP_PADDING_MAX_ITER=6
CLIP_THRESHOLD=0.05
CLIP_CROP_DIVISOR=11
CLIP_MARKER_SUFFIX=.CLIPPED
# 1 = clip-detect on by default (single-file; batch --no-clip-queue injects same unless --no-clip-detect). --clip-detect / --no-clip-detect override.
DEFAULT_CLIP_DETECT=1
DEFAULT_SIZE=1024
LOGO_RATIO=824
WEBP_QUALITY=95
WEBP_METHOD=4
RETRY_ATTEMPTS=3
RETRY_SLEEP=1
MAGICK=/opt/homebrew/bin/magick
[[ -x "$MAGICK" ]] || MAGICK=/usr/local/bin/magick
SIPS=/usr/bin/sips
MASK_FILE="${SCRIPT_DIR}/mask.png"
# Optional post-render “store-style” plate (after main render, before metadata strip).
# Mimics a light top / slightly darker bottom + optional floating shadow — tune to taste; not pixel-Apple.
PLATE_FX=1
PLATE_FX_GRADIENT='rgba(255,255,255,0.14)-rgba(0,0,0,0.10)'
PLATE_FX_DROP_SHADOW=''
# Example: PLATE_FX=1 and PLATE_FX_DROP_SHADOW='70x4+0+14' (ImageMagick -shadow: opacity%xsigma+dx+dy)
# =============================================================================

typeset -g SQUIRCLE_TMPBASE="${SQUIRCLE_TMP_PARENT}/squircle_$$"

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
  # Belt-and-suspenders: known suffixes only. Never call `rm -f` with zero operands (zsh null_glob + no
  # matches → BSD rm exits 1 → ERR trap → bogus failure after successful WebP write; breaks GNU parallel).
  if [[ -n "${SQUIRCLE_TMPBASE:-}" ]]; then
    rm -f \
      "${SQUIRCLE_TMPBASE}.mask.png" \
      "${SQUIRCLE_TMPBASE}.tmp.png" \
      "${SQUIRCLE_TMPBASE}.svg.png" \
      "${SQUIRCLE_TMPBASE}.clip_frame.png" \
      "${SQUIRCLE_TMPBASE}.clip_masked.png" \
      "${SQUIRCLE_TMPBASE}.clip_diff.png" \
      "${SQUIRCLE_TMPBASE}.clip_frame_flat.png" \
      "${SQUIRCLE_TMPBASE}.clip_masked_flat.png" \
      "${SQUIRCLE_TMPBASE}.plate_fx.png" \
      "${SQUIRCLE_TMPBASE}.plate_fx2.png" \
      "${SQUIRCLE_TMPBASE}.jobs.tsv" 2>/dev/null || true
    if [[ -d "${SQUIRCLE_TMPBASE}.ql.d" ]]; then
      rm -rf "${SQUIRCLE_TMPBASE}.ql.d"
    fi
  fi
  :
}
trap 'cleanup; exit' EXIT
trap 'cleanup; exit 1' ERR
trap cleanup SIGTERM SIGINT

# --- Help (scriptify requirement) ---
show_help() {
  cat << EOF
Usage: $SCRIPT_NAME <input> [options] [--out path.webp]

  One image in → squircle WebP out (default size from CONFIG: DEFAULT_SIZE).

  Tunables: edit CONFIG at top of this script (REPO_ROOT, PARALLEL_J, DEFAULT_CLIP_DETECT,
  clip/WebP/retry paths, PLATE_FX optional post polish, etc.). No env vars.

Options:
  --bg #HEX        Background color (e.g. #FFFFFF). With --padding, margin color.
  --icon-color #   Recolor logo (transparent-background path only).
  --size N         Output size (default: CONFIG DEFAULT_SIZE).
  --out path.webp  Output path. Default: REPO_ROOT/webp/<input_basename>.webp (REPO_ROOT = parent of bin/).
  --out-dir DIR    Output directory (batch mode only). Default REPO_ROOT/webp if omitted. Created if missing.
                   Directory mode is recursive and preserves the input folder structure:
                   <out-dir>/<relative_path_from_input>/<basename>.webp (existing files are skipped).
  --clip-queue     Batch: clip-detect + padding escalation via GNU Parallel (-j CONFIG PARALLEL_J unless --parallel-j).
  --clip-queue-sequential  Same as --clip-queue but one job at a time (low RAM / ordered logs).
  --no-clip-queue  Batch: parallel (-j same as above), no clip-detect / no padding escalation (skip exists unless --overwrite).
  --parallel-j ARG  Batch: GNU Parallel -j ARG (e.g. 100%, 125%, 200%, 0). Default: CONFIG PARALLEL_J.
                   With --clip-detect on a single file, creates <output>${CLIP_MARKER_SUFFIX} if still clipped after max tries.
  --clip-keep-markers  Keep clip marker sidecars after queue finishes (otherwise deleted; report kept).
  --clip-padding-start N   Initial padding px (default: CONFIG CLIP_PADDING_START).
  --clip-padding-step  N   Padding increment per iteration (default: CONFIG CLIP_PADDING_STEP).
  --clip-padding-max-iter K Max padding iterations (default: CONFIG CLIP_PADDING_MAX_ITER).
  --clip-threshold X       Clipping threshold (default: CONFIG CLIP_THRESHOLD).
  --clip-crop-divisor D   Corner crop size = size/D (default: CONFIG CLIP_CROP_DIVISOR).
  --clip-detect-only        Compute clip markers but do not write WebP.
  --clip-detect             Force clip-detect on (default is CONFIG DEFAULT_CLIP_DETECT).
  --no-clip-detect          Force clip-detect off (escape hatch when DEFAULT_CLIP_DETECT=1).
  --overwrite               Directory mode: overwrite existing outputs.
  --padding [N]    Center logo with margin. N = padding in px per side (default ~100); omit for default.
  -h, --help       Show this help.

  Batch interrupt: Use Ctrl+C once and wait. Do not Ctrl+Z (suspends). Hammering Ctrl+C can hit GNU Parallel's signal limit.

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

# --- Router: if first arg is a directory → batch, then exit ---
if [[ $# -ge 1 && -d "$1" ]]; then
  command -v parallel &>/dev/null || { echo "GNU Parallel required: brew install parallel"; exit 1; }

  typeset -a argv=("$@")
  typeset out_dir=""
  typeset clip_queue=1
  typeset clip_padding_start="$CLIP_PADDING_START"
  typeset clip_padding_step="$CLIP_PADDING_STEP"
  typeset clip_padding_max_iter="$CLIP_PADDING_MAX_ITER"
  typeset clip_threshold="$CLIP_THRESHOLD"
  typeset clip_crop_divisor="$CLIP_CROP_DIVISOR"
  typeset overwrite=0
  typeset clip_keep_markers=0
  typeset clip_queue_sequential=0
  typeset parallel_jobs="$PARALLEL_J"

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
      --clip-queue-sequential) clip_queue_sequential=1 ;;
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
      --parallel-j=*) parallel_jobs="${a#--parallel-j=}" ;;
      --parallel-j)
        if (( idx < $#argv )); then parallel_jobs="${argv[$((idx+1))]}"; fi ;;
    esac
  done

  [[ -z "$out_dir" ]] && out_dir="${REPO_ROOT}/webp"
  [[ -d "$out_dir" ]] || mkdir -p "$out_dir"

  # When CONFIG DEFAULT_CLIP_DETECT=1, batch children get clip args unless user passed --no-clip-detect.
  typeset batch_clip_inject=0
  (( DEFAULT_CLIP_DETECT == 1 )) && batch_clip_inject=1
  for a in "${argv[@]}"; do
    [[ "$a" == --no-clip-detect ]] && batch_clip_inject=0
  done

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
      --clip-queue-sequential) : ;;
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
      --parallel-j) skip_next=1 ;;
      --parallel-j=*) : ;;
      --clip-detect) : ;;
      --clip-detect-only) : ;;
      --padding) skip_next=1 ;;
      --padding=*) : ;;
      *) pass_args+=("$a") ;;
    esac
  done

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
  # Use a job file + :::: instead of printf | parallel so the foreground process is only `parallel` (cleaner Ctrl+C/Ctrl+Z
  # than a pipeline suspended as one unit).
  run_parallel_by_indexes() {
    typeset -a idxs=("$@")
    if (( ${#idxs[@]} == 0 )); then return 0; fi

    local jf="${SQUIRCLE_TMPBASE}.jobs.tsv"
    : > "$jf"
    for k in "${idxs[@]}"; do
      printf '%s\t%s\n' "${all_inputs[$k]}" "${all_outputs[$k]}"
    done > "$jf"

    if (( ${#idxs[@]} > 15 )) && (( clip_queue_sequential == 0 )); then
      print -r -- "squircle: GNU Parallel -j ${parallel_jobs} — stop with one Ctrl+C (wait); avoid Ctrl+Z / machine-gun Ctrl+C." >&2
    fi

    parallel --no-notice -j "$parallel_jobs" --colsep '\t' \
      "$SCRIPT_DIR/$SCRIPT_NAME" {1} --out {2} "${CLIP_EXTRA_ARGS[@]}" "${pass_args[@]}" :::: "$jf"
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
    # One parallel pass: each child is independent ($$, SQUIRCLE_TMPBASE, unique OUTPUT); same clip args as before.
    typeset -a idxs=()
    for ((i=1; i<=${#all_inputs[@]}; i++)); do idxs+=("$i"); done
    typeset -a CLIP_EXTRA_ARGS=()
    if (( batch_clip_inject == 1 )); then
      CLIP_EXTRA_ARGS=(
        --clip-detect
        --clip-threshold "$clip_threshold"
        --clip-crop-divisor "$clip_crop_divisor"
        --clip-padding-start "$clip_padding_start"
        --clip-padding-step "$clip_padding_step"
        --clip-padding-max-iter "$clip_padding_max_iter"
      )
    fi
    if (( clip_queue_sequential == 1 )); then
      run_sequential_by_indexes "${idxs[@]}"
    else
      run_parallel_by_indexes "${idxs[@]}"
    fi
  else
    # Normal batch mode: run over all_inputs/all_outputs (already filtered by skip/overwrite).
    typeset -a idxs=()
    for ((i=1; i<=${#all_inputs[@]}; i++)); do idxs+=("$i"); done
    typeset -a CLIP_EXTRA_ARGS=()
    if (( batch_clip_inject == 1 )); then
      CLIP_EXTRA_ARGS=(
        --clip-detect
        --clip-threshold "$clip_threshold"
        --clip-crop-divisor "$clip_crop_divisor"
        --clip-padding-start "$clip_padding_start"
        --clip-padding-step "$clip_padding_step"
        --clip-padding-max-iter "$clip_padding_max_iter"
      )
    fi
    run_parallel_by_indexes "${idxs[@]}"
  fi

  # Clip markers are debug-only by default.
  # If markers remain after max iterations, write an "unfixed" report
  # and delete the marker files to avoid clutter.
  if (( clip_queue == 1 && clip_keep_markers == 0 && batch_clip_inject == 1 )); then
    report="${out_dir}/.clip_queue_unfixed.txt"
    : > "$report"
    for ((i=1; i<=${#all_outputs[@]}; i++)); do
      marker="${all_outputs[$i]}${CLIP_MARKER_SUFFIX}"
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
  typeset -g CLIP_PADDING_START CLIP_PADDING_STEP CLIP_PADDING_MAX_ITER
  BG_OVERRIDE=(); ICON_COLOR=(); SIZE=(); OUTPUT=(); INPUT=""
  OPAQUE_PADDING=0; PADDING_PX=""
  CLIP_DETECT=$(( DEFAULT_CLIP_DETECT ? 1 : 0 ))
  CLIP_DETECT_ONLY=0
  typeset -a args=()
  next=""
  for a in "${save_args[@]}"; do
    if [[ "$next" == "bg" ]]; then BG_OVERRIDE="$a"; next=""; continue; fi
    if [[ "$next" == "icon-color" ]]; then ICON_COLOR="$a"; next=""; continue; fi
    if [[ "$next" == "size" ]]; then SIZE="$a"; next=""; continue; fi
    if [[ "$next" == "out" ]]; then OUTPUT="$a"; next=""; continue; fi
    if [[ "$next" == "clip-threshold" ]]; then CLIP_THRESHOLD="$a"; next=""; continue; fi
    if [[ "$next" == "clip-crop-divisor" ]]; then CLIP_CROP_DIVISOR="$a"; next=""; continue; fi
    if [[ "$next" == "clip-padding-start" ]]; then CLIP_PADDING_START="$a"; next=""; continue; fi
    if [[ "$next" == "clip-padding-step" ]]; then CLIP_PADDING_STEP="$a"; next=""; continue; fi
    if [[ "$next" == "clip-padding-max-iter" ]]; then CLIP_PADDING_MAX_ITER="$a"; next=""; continue; fi
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
      --no-clip-detect) CLIP_DETECT=0 ;;
      --clip-detect-only) CLIP_DETECT=1; CLIP_DETECT_ONLY=1 ;;
      --clip-threshold) next="clip-threshold" ;;
      --clip-crop-divisor) next="clip-crop-divisor" ;;
      --clip-padding-start) next="clip-padding-start" ;;
      --clip-padding-start=*) CLIP_PADDING_START="${a#--clip-padding-start=}" ;;
      --clip-padding-step) next="clip-padding-step" ;;
      --clip-padding-step=*) CLIP_PADDING_STEP="${a#--clip-padding-step=}" ;;
      --clip-padding-max-iter) next="clip-padding-max-iter" ;;
      --clip-padding-max-iter=*) CLIP_PADDING_MAX_ITER="${a#--clip-padding-max-iter=}" ;;
      *) args+=("$a") ;;
    esac
  done
  [[ "$next" == "padding" ]] && { OPAQUE_PADDING=1; next=""; }
  [[ ${#args[@]} -lt 1 ]] && { echo "🔴 Usage: $0 <input> [--bg #HEX] [--icon-color #HEX] [--size 1024] [--out path.webp] [--padding [N]] [--clip-detect|--no-clip-detect|--clip-detect-only] [--clip-threshold X] [--clip-crop-divisor D] [--clip-padding-start N] [--clip-padding-step N] [--clip-padding-max-iter K]" >&2; exit 1; }
  INPUT="${args[1]}"
  if [[ -f "$INPUT" ]] && [[ "${INPUT:A}" -ef "${0:A}" ]]; then
    echo "🔴 First argument must be the image (or a directory for batch), not $SCRIPT_NAME." >&2
    echo "   You probably duplicated the script path. Example:" >&2
    echo "   $SCRIPT_NAME /path/to/icon.webp [--out path.webp]" >&2
    exit 1
  fi
  # Only use args[2] as OUTPUT if it looks like a path (has . or /), not a number
  if [[ -z "$OUTPUT" && -n "${args[2]:-}" && "${args[2]}" != --* ]]; then
    [[ "${args[2]}" == *.* || "${args[2]}" == */* ]] && OUTPUT="${args[2]}"
  fi
  [[ -z "$SIZE" && -n "${args[3]:-}" && "${args[3]}" != --* ]] && SIZE="${args[3]}"
  [[ ! -f "$INPUT" ]] && { echo "🔴 Not a file: $INPUT" >&2; exit 1; }
  : "${SIZE:=$DEFAULT_SIZE}"
  if [[ -z "$OUTPUT" ]]; then
    mkdir -p "$REPO_ROOT/webp"
    OUTPUT="$REPO_ROOT/webp/${INPUT:t:r}.webp"
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
    TMP_PNG="${SQUIRCLE_TMPBASE}.tmp.png"
    retry_run $SIPS -s format png "$raw" --out "$TMP_PNG" && IN_FOR_MAGICK="$TMP_PNG"
  fi
  # .ico / .cur → first frame to PNG (multi-resolution; use [0])
  if [[ "$raw" == *".ico" ]] || [[ "$raw" == *".cur" ]]; then
    TMP_PNG="${SQUIRCLE_TMPBASE}.tmp.png"
    retry_run $MAGICK -limit thread 1 "${raw}[0]" -resize "${size}x${size}" "$TMP_PNG" && IN_FOR_MAGICK="$TMP_PNG"
  fi
  # .svg / .svgz → PNG (rsvg-convert or macOS Quick Look)
  if [[ "$raw" == *".svg" ]] || [[ "$raw" == *".svgz" ]]; then
    local rsvg=/opt/homebrew/bin/rsvg-convert
    [[ -x "$rsvg" ]] || rsvg=/usr/local/bin/rsvg-convert
    if [[ -x "$rsvg" ]]; then
      TMP_SVG_PNG="${SQUIRCLE_TMPBASE}.svg.png"
      retry_run $rsvg -w "$size" -h "$size" "$raw" -o "$TMP_SVG_PNG" && IN_FOR_MAGICK="$TMP_SVG_PNG"
    fi
    if [[ "$(uname)" == Darwin ]] && { [[ -z "$IN_FOR_MAGICK" ]] || [[ "$IN_FOR_MAGICK" == "$raw" ]]; }; then
      TMP_QL_DIR="${SQUIRCLE_TMPBASE}.ql.d"
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
  typeset -g MASK_TMP="${SQUIRCLE_TMPBASE}.mask.png"
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

  CLIP_FRAME_TMP="${SQUIRCLE_TMPBASE}.clip_frame.png"
  CLIP_MASKED_TMP="${SQUIRCLE_TMPBASE}.clip_masked.png"
  CLIP_DIFF_TMP="${SQUIRCLE_TMPBASE}.clip_diff.png"
  CLIP_FRAME_FLAT_TMP="${SQUIRCLE_TMPBASE}.clip_frame_flat.png"
  CLIP_MASKED_FLAT_TMP="${SQUIRCLE_TMPBASE}.clip_masked_flat.png"

  if [[ $OPAQUE_PADDING -eq 1 ]]; then
    # Padding mode unmasked: scaled logo centered with margin background.
    $MAGICK -limit thread 1 \
      \( "$raster" -resize "${logo_size}x${logo_size}^" -gravity center -background "$padding_bg" -extent "${size}x${size}" \) \
      -strip "$CLIP_FRAME_TMP"
  else
    # Fill mode unmasked: trim transparent edges then scale-to-fill the frame.
    $MAGICK -limit thread 1 \
      \( "$raster" -trim +repage -resize "${size}x${size}^" -gravity center -extent "${size}x${size}" \) \
      -strip "$CLIP_FRAME_TMP"
  fi

  # Apply squircle mask (creates transparency outside rounded shape).
  $MAGICK -limit thread 1 "$CLIP_FRAME_TMP" "$mask" -alpha off -compose CopyOpacity -composite "$CLIP_MASKED_TMP"

  # Flatten both against the unmasked frame's corner background color,
  # then compute a corner-only difference score.
  local diff_bg_hex
  diff_bg_hex="$(sample_corner_bg_hex "$CLIP_FRAME_TMP" || echo "#FFFFFF")"
  $MAGICK -limit thread 1 "$CLIP_FRAME_TMP" -background "$diff_bg_hex" -alpha remove -alpha off "$CLIP_FRAME_FLAT_TMP" >/dev/null 2>&1 || cp "$CLIP_FRAME_TMP" "$CLIP_FRAME_FLAT_TMP"
  $MAGICK -limit thread 1 "$CLIP_MASKED_TMP" -background "$diff_bg_hex" -alpha remove -alpha off "$CLIP_MASKED_FLAT_TMP" >/dev/null 2>&1 || cp "$CLIP_MASKED_TMP" "$CLIP_MASKED_FLAT_TMP"

  $MAGICK -limit thread 1 "$CLIP_FRAME_FLAT_TMP" "$CLIP_MASKED_FLAT_TMP" -alpha off -compose difference -composite "$CLIP_DIFF_TMP" >/dev/null 2>&1 || true

  tl=$($MAGICK -limit thread 1 "$CLIP_DIFF_TMP" -crop ${crop_px}x${crop_px}+0+0 +repage -format "%[fx:mean]" info: 2>/dev/null | tr -d '\n' || echo "")
  tr=$($MAGICK -limit thread 1 "$CLIP_DIFF_TMP" -crop ${crop_px}x${crop_px}+${x}+0 +repage -format "%[fx:mean]" info: 2>/dev/null | tr -d '\n' || echo "")
  bl=$($MAGICK -limit thread 1 "$CLIP_DIFF_TMP" -crop ${crop_px}x${crop_px}+0+${y} +repage -format "%[fx:mean]" info: 2>/dev/null | tr -d '\n' || echo "")
  br=$($MAGICK -limit thread 1 "$CLIP_DIFF_TMP" -crop ${crop_px}x${crop_px}+${x}+${y} +repage -format "%[fx:mean]" info: 2>/dev/null | tr -d '\n' || echo "")

  clip_score=$(awk -v tl="$tl" -v tr="$tr" -v bl="$bl" -v br="$br" 'BEGIN{print (tl+tr+bl+br)/4}' 2>/dev/null || echo "1")
  # Padding path: corner samples overlap squircle anti-alias vs square margin → mean diff often ~0.06–0.09
  # with no visible logo clip. Use looser effective threshold vs fill-only (strict) path.
  local eff_threshold="$CLIP_THRESHOLD"
  if [[ $OPAQUE_PADDING -eq 1 ]]; then
    eff_threshold=$(awk -v t="$CLIP_THRESHOLD" 'BEGIN{printf "%.5f", t*1.75}')
  fi
  clipped=$(awk -v s="$clip_score" -v t="$eff_threshold" 'BEGIN{print (s>=t)?1:0}' 2>/dev/null || echo "1")

  marker="${OUTPUT}${CLIP_MARKER_SUFFIX}"
  if [[ "$clipped" == "1" ]]; then
    : > "$marker"
  else
    [[ -f "$marker" ]] && rm -f "$marker"
  fi
}

# When clip-detect says the opaque render would clip, rerender with numeric padding,
# increasing until the marker clears or we hit max_iter (same defaults as batch clip-queue).
mitigate_opaque_clipping() {
  local start_pad="$1" step="$2" max_iter="$3"
  local pad="$start_pad" iter=0 ls margin

  while (( iter < max_iter )); do
    typeset -g OPAQUE_PADDING=1
    typeset -g PADDING_PX=$pad
    ls=$(( SIZE - 2 * PADDING_PX ))
    (( ls < 8 )) && ls=8
    margin="#FFFFFF"
    if (( ${#BG_OVERRIDE[@]} > 0 )); then
      margin="$BG_OVERRIDE[1]"
    fi
    if [[ "$BG_HEX" == "OPAQUE" && "$margin" == "#FFFFFF" ]]; then
      margin="$(sample_corner_bg_hex "$IN_FOR_MAGICK" || echo "#FFFFFF")"
    fi
    compute_clip_marker "$IN_FOR_MAGICK" "$MASK_TMP" "$SIZE" "$margin" "$ls" || true
    render_opaque_padding "$IN_FOR_MAGICK" "$MASK_TMP" "$OUTPUT" "$SIZE" "$margin" "$ls"
    [[ ! -f "${OUTPUT}${CLIP_MARKER_SUFFIX}" ]] && return 0
    pad=$(( pad + step ))
    iter=$(( iter + 1 ))
  done
  return 0
}

# --- Optional post-render plate polish (App-Store-ish depth; approximate) ---
apply_plate_fx() {
  [[ "${PLATE_FX:-0}" -eq 1 ]] || return 0
  local out="$1" sz="$2"
  [[ -f "$out" ]] || return 0
  local w=$sz h=$sz
  local tmp="${SQUIRCLE_TMPBASE}.plate_fx.png"
  local tmp2="${SQUIRCLE_TMPBASE}.plate_fx2.png"
  local grad="${PLATE_FX_GRADIENT:-}"

  if [[ -n "$grad" ]]; then
    $MAGICK -limit thread 1 "$out" \
      \( +clone -alpha extract \) -write mpr:palpha +delete \
      \( -size "${w}x${h}" gradient:"$grad" \) \
      -compose SoftLight -composite \
      mpr:palpha -compose CopyOpacity -composite \
      PNG32:"$tmp"
  else
    $MAGICK -limit thread 1 "$out" PNG32:"$tmp"
  fi

  local ds="${PLATE_FX_DROP_SHADOW:-}"
  if [[ -n "$ds" ]]; then
    $MAGICK -limit thread 1 -size "${w}x${h}" xc:none \
      \( PNG32:"$tmp" -background black -shadow "$ds" \) -gravity center -compose Over -composite \
      \( PNG32:"$tmp" \) -gravity center -compose Over -composite \
      PNG32:"$tmp2"
    mv -f "$tmp2" "$tmp"
  fi

  $MAGICK -limit thread 1 PNG32:"$tmp" -define webp:method="$WEBP_METHOD" -quality "$WEBP_QUALITY" "$out"
  rm -f "$tmp" "$tmp2" 2>/dev/null || true
}

# --- Strip metadata (repo standard) ---
strip_metadata() {
  exiftool -all= -overwrite_original -q -q "$1" 2>/dev/null || true
  xattr -c "$1" 2>/dev/null || true
}

# --- Main: parse → normalize → background → mask → one of three render paths → strip metadata ---
main() {
  parse_args "$@"
  # Single-file --out may point at deep paths; batch mode mkdirs in router, but children only get --out.
  [[ -n "$OUTPUT" ]] && mkdir -p "${OUTPUT:h}"
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
    if (( CLIP_DETECT == 1 )); then
      if [[ $OPAQUE_PADDING -eq 1 ]]; then
        if [[ -f "${OUTPUT}${CLIP_MARKER_SUFFIX}" ]]; then
          local mit_start="$CLIP_PADDING_START"
          if [[ -n "$PADDING_PX" && "$PADDING_PX" -ge 0 ]]; then
            mit_start=$(( PADDING_PX + CLIP_PADDING_STEP ))
          fi
          mitigate_opaque_clipping "$mit_start" "$CLIP_PADDING_STEP" "$CLIP_PADDING_MAX_ITER"
        else
          render_opaque_padding "$IN_FOR_MAGICK" "$MASK_TMP" "$OUTPUT" "$SIZE" "$padding_bg" "$logo_size"
        fi
      else
        if [[ -f "${OUTPUT}${CLIP_MARKER_SUFFIX}" ]]; then
          mitigate_opaque_clipping "$CLIP_PADDING_START" "$CLIP_PADDING_STEP" "$CLIP_PADDING_MAX_ITER"
        else
          # Fill heuristic said OK but fill still pins art to the squircle rim (tips die on the curve). With
          # --clip-detect, never emit fill-only opaque WebPs; minimum inset matches prior "working" batch look.
          typeset -g OPAQUE_PADDING=1
          typeset -g PADDING_PX=$CLIP_PADDING_START
          local safe_logo=$(( SIZE - 2 * CLIP_PADDING_START ))
          (( safe_logo < 8 )) && safe_logo=8
          local margin="#FFFFFF"
          if (( ${#BG_OVERRIDE[@]} > 0 )); then margin="$BG_OVERRIDE[1]"; fi
          if [[ "$margin" == "#FFFFFF" ]]; then
            margin="$(sample_corner_bg_hex "$IN_FOR_MAGICK" || echo "#FFFFFF")"
          fi
          compute_clip_marker "$IN_FOR_MAGICK" "$MASK_TMP" "$SIZE" "$margin" "$safe_logo" || true
          render_opaque_padding "$IN_FOR_MAGICK" "$MASK_TMP" "$OUTPUT" "$SIZE" "$margin" "$safe_logo"
        fi
      fi
    else
      if [[ $OPAQUE_PADDING -eq 1 ]]; then
        render_opaque_padding "$IN_FOR_MAGICK" "$MASK_TMP" "$OUTPUT" "$SIZE" "$padding_bg" "$logo_size"
      else
        render_opaque_fill "$IN_FOR_MAGICK" "$MASK_TMP" "$OUTPUT" "$SIZE"
      fi
    fi
  else
    render_with_base "$IN_FOR_MAGICK" "$MASK_TMP" "$OUTPUT" "$SIZE" "$BG_HEX" "$ICON_COLOR" "$logo_size"
  fi

  apply_plate_fx "$OUTPUT" "$SIZE"
  strip_metadata "$OUTPUT"
  if [[ "$BG_HEX" == "OPAQUE" ]]; then
    if [[ $OPAQUE_PADDING -eq 1 ]]; then
      if [[ -n "$PADDING_PX" ]]; then
        echo "🟢 $OUTPUT (${SIZE}×${SIZE}, mode: padding ${PADDING_PX}px — transparent outside squircle)"
      else
        echo "🟢 $OUTPUT (${SIZE}×${SIZE}, mode: padding (inset) — transparent outside squircle)"
      fi
    else
      echo "🟢 $OUTPUT (${SIZE}×${SIZE}, mode: fill — transparent outside squircle)"
    fi
  else
    echo "🟢 $OUTPUT (${SIZE}×${SIZE}, bg ${BG_HEX})"
  fi
}

main "$@"
