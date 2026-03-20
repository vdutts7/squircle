#!/bin/zsh
# Parallel logo fetch for one domain; compare geometry + bytes. Optional: run squircle on winner.
# Usage:
#   logo-rip.zsh <domain> [--keep] [--squircle] [--out path.webp]
# Default squircle out: REPO_ROOT/webp/<domain-dots-to-dashes>.webp
# Deps: curl, magick. Not legal advice; respect each provider's terms.

set -e
setopt pipefail 2>/dev/null || true

SCRIPT_DIR="${0:h}"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SQUIRCLE="$SCRIPT_DIR/squircle.sh"

usage() {
  echo "usage: $0 <domain> [--keep] [--squircle] [--out path.webp]" >&2
  exit 1
}

[[ -n "${1:-}" ]] || usage

MAGICK=/opt/homebrew/bin/magick
[[ -x "$MAGICK" ]] || MAGICK=/usr/local/bin/magick
command -v curl &>/dev/null || { echo "need curl" >&2; exit 1; }
[[ -x "$MAGICK" ]] || { echo "need magick (identify)" >&2; exit 1; }
[[ -x "$SQUIRCLE" ]] || { echo "need $SQUIRCLE" >&2; exit 1; }

d_raw="$1"
shift
typeset keep=0 run_sq=0 out_webp=""
while [[ -n "${1:-}" ]]; do
  case "$1" in
    --keep) keep=1; shift ;;
    --squircle) run_sq=1; shift ;;
    --out=*) out_webp="${1#--out=}"; shift ;;
    --out)
      shift
      [[ -n "${1:-}" ]] || { echo "error: --out needs a path" >&2; exit 1; }
      out_webp="$1"
      shift
      ;;
    *) echo "error: unknown flag: $1" >&2; usage ;;
  esac
done

d="${d_raw:l}"
d="${d#https://}"
d="${d#http://}"
d="${d%%/*}"
d="${d#www.}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/logo-rip.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
(( keep )) || trap cleanup EXIT

typeset -a SRC=(
  "hunter|https://logos.hunter.io/${d}"
  "clearbit|https://logo.clearbit.com/${d}"
  "g256|https://www.google.com/s2/favicons?domain=${d}&sz=256"
  "g128|https://www.google.com/s2/favicons?domain=${d}&sz=128"
  "ddg|https://icons.duckduckgo.com/ip3/${d}.ico"
  "apple|https://${d}/apple-touch-icon.png"
  "apple-www|https://www.${d}/apple-touch-icon.png"
  "favicon|https://${d}/favicon.ico"
  "favicon-www|https://www.${d}/favicon.ico"
)

rip_one() {
  local name="${1%%|*}" url="${1#*|}"
  local out="${TMP}/${name}.bin"
  if curl -sfL --max-time 20 -A "squircle-logo-rip/1.0" "$url" -o "$out" 2>/dev/null && [[ -s "$out" ]]; then
    :
  else
    rm -f "$out"
  fi
}

for row in "${SRC[@]}"; do
  rip_one "$row" &
done
wait

typeset -a LOGO_ROWS
for f in "$TMP"/*.bin(N); do
  [[ -s "$f" ]] || continue
  base="${f:t:r}"
  meta="$("$MAGICK" identify -format '%m %wx%h %b' "${f}[0]" 2>/dev/null | head -n1)" || continue
  read -r fmt wh sz <<<"${meta//,/}"
  [[ -n "$wh" ]] || continue
  w="${wh%x*}"
  h="${wh#*x}"
  max=$(( w > h ? w : h ))
  bytes="$(wc -c <"$f" | tr -d '[:space:]')"
  printf -v pad '%05d' "$max"
  LOGO_ROWS+=( "${pad}"$'\t'"${base}"$'\t'"${fmt}"$'\t'"${wh}"$'\t'"${sz}"$'\t'"${bytes}" )
done

print -r -- "domain: $d"
print -r -- $'maxPx\tsource\tformat\tgeometry\tsize_field\tbytes'
if (( ! ${#LOGO_ROWS[@]} )); then
  print -r -- "(no valid images downloaded)"
  exit 1
fi

printf '%s\n' "${LOGO_ROWS[@]}" | LC_ALL=C sort -t $'\t' -k1,1nr
print -r -- ""
best="$(printf '%s\n' "${LOGO_ROWS[@]}" | LC_ALL=C sort -t $'\t' -k1,1nr | head -n1)"
print -r -- "best_line: $best"
print -r -- "tmpdir: $TMP"
(( keep )) && print -r -- "(kept on disk; rm -rf manually when done)"

IFS=$'\t' read -r _pad best_src best_fmt _g _s _b <<<"$best"
best_bin="${TMP}/${best_src}.bin"
[[ -s "$best_bin" ]] || { echo "error: missing winner file" >&2; exit 1; }

if (( run_sq )); then
  ext="${(L)best_fmt}"
  case "$ext" in
    png|jpeg|jpg|webp|avif|gif|ico|svg|bmp|tiff|tif) ;;
    *) ext=png ;;
  esac
  [[ "$ext" == jpeg ]] && ext=jpg
  rip_in="${TMP}/squircle-input.${ext}"
  cp "$best_bin" "$rip_in"
  [[ -n "$out_webp" ]] || out_webp="$REPO_ROOT/webp/${d//./-}.webp"
  mkdir -p "${out_webp:h}"
  print -r -- "squircle: $rip_in -> $out_webp"
  "$SQUIRCLE" "$rip_in" --out "$out_webp"
fi
