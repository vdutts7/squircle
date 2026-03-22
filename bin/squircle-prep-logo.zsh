#!/bin/zsh
# squircle-prep-logo.zsh — content-bounds / margin trim for fetched logos.
# Sourced by squircle.sh (--domain). Not meant as a standalone CLI.
#
# squircle_prep_logo_raster <in_file> <out_png>
#   Writes PNG32. Expects globals: MAGICK (executable). Optional: MAGICK_RF (array),
#   SQUIRCLE_PREP_FUZZ (default 12, percent for -fuzz trim),
#   SQUIRCLE_PREP_MIN_AREA_FRAC (default 8 = keep trim only if trimmed area ≥ 8% of original).
# Returns 0 on success (out may be a safe copy of in if trim was rejected).

squircle_prep_logo_raster() {
  local in="$1" out="$2"
  [[ -n "$in" && -n "$out" && -f "$in" ]] || return 1
  [[ -x "${MAGICK:-}" ]] || return 1

  local fuzz="${SQUIRCLE_PREP_FUZZ:-12}"
  local min_pct="${SQUIRCLE_PREP_MIN_AREA_FRAC:-8}"
  typeset -a rf=()
  [[ -n "${MAGICK_RF[*]:-}" ]] && rf=( "${MAGICK_RF[@]}" )

  local ow oh nw nh oa na
  read ow oh <<<"$("$MAGICK" identify -format '%w %h' "${in}[0]" 2>/dev/null)"
  [[ -n "$ow" && -n "$oh" ]] || return 1
  oa=$(( ow * oh ))

  if ! "$MAGICK" -limit thread 1 "${in}[0]" "${rf[@]}" \
      -coalesce \
      -fuzz "${fuzz}%" -trim +repage \
      PNG32:"$out" 2>/dev/null; then
    cp -f "$in" "$out" 2>/dev/null || return 1
    return 0
  fi
  [[ -s "$out" ]] || { cp -f "$in" "$out" 2>/dev/null || return 1; return 0 }

  read nw nh <<<"$("$MAGICK" identify -format '%w %h' "${out}[0]" 2>/dev/null)"
  [[ -n "$nw" && -n "$nh" ]] || { cp -f "$in" "$out" 2>/dev/null || return 1; return 0 }
  na=$(( nw * nh ))

  # Reject over-aggressive trim (e.g. bad fuzz on noisy edges).
  if (( oa > 0 && na * 100 < oa * min_pct )); then
    cp -f "$in" "$out" 2>/dev/null || return 1
    return 0
  fi

  # Reject degenerate output.
  if (( nw < 2 || nh < 2 )); then
    cp -f "$in" "$out" 2>/dev/null || return 1
    return 0
  fi

  # Reject trim that slaughtered one axis (e.g. square 1667² → 918×1518): fuzz ate horizontal logo bars;
  # squircle's opaque ^-resize then center-crops → letter junk. Keep full input instead.
  local rw rh rmin rmax
  (( ow > 0 )) && rw=$(( nw * 100 / ow )) || rw=100
  (( oh > 0 )) && rh=$(( nh * 100 / oh )) || rh=100
  rmin=$(( rw < rh ? rw : rh ))
  rmax=$(( rw > rh ? rw : rh ))
  if (( rmin < 62 && rmax > 88 )); then
    cp -f "$in" "$out" 2>/dev/null || return 1
    return 0
  fi

  return 0
}
