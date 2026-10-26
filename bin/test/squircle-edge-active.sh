#!/usr/bin/env zsh
# squircle edge-case-matrix active_run — live probes (repo SSOT)
setopt errexit pipefail nounset
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SQUIRCLE_ROOT="${SQUIRCLE:-$ROOT}"
export SQUIRCLE="$SQUIRCLE_ROOT"
MAGICK="${MAGICK:-/opt/homebrew/bin/magick}"
[[ -x "$MAGICK" ]] || MAGICK=/usr/local/bin/magick

pass=0
fail=0
ok() { print -u2 "  ok $1"; pass=$((pass + 1)); }
bad() { print -u2 "  FAIL $1"; fail=$((fail + 1)); }
probe() { print -u2 "PROBE $1"; }

probe SQ-PLAT-01
[[ -x "$SQUIRCLE_ROOT/bin/squircle.sh" ]] && ok "squircle.sh" || bad "squircle.sh"
[[ -f "$SQUIRCLE_ROOT/bin/mask.png" ]] && ok "mask.png" || bad "mask.png"
[[ -x "$MAGICK" ]] && ok "magick" || bad "magick"
[[ -x "$SQUIRCLE_ROOT/bin/get-bg-color.sh" ]] && ok "get-bg-color.sh" || bad "get-bg-color"

probe SQ-CLI-01
set +e
"$SQUIRCLE_ROOT/bin/squircle.sh" >/dev/null 2>&1
rc=$?
set -e
(( rc != 0 )) && ok "no-args exits non-zero" || bad "no-args should fail"

probe SQ-CLI-02
set +e
"$SQUIRCLE_ROOT/bin/squircle.sh" "$SQUIRCLE_ROOT/bin/squircle.sh" >/dev/null 2>&1
rc=$?
set -e
(( rc != 0 )) && ok "self-as-input refused" || bad "self-as-input"

probe SQ-CLI-03
set +e
out="$("$SQUIRCLE_ROOT/bin/squircle.sh" --help 2>&1)"
rc=$?
set -e
(( rc == 0 )) && print -r -- "$out" | grep -q padding && ok "--help documents padding" || bad "--help"

probe SQ-SHELL-01
# Public-repo semantics: execution plane is repo bin/ (CUR mirror optional, not required).
[[ -x "$SQUIRCLE_ROOT/bin/squircle.sh" ]] && ok "repo bin/squircle.sh" || bad "repo bin/squircle.sh"
head -n1 "$SQUIRCLE_ROOT/bin/squircle.sh" | grep -qE '^#!' && ok "shebang present" || bad "shebang"

probe SQ-FS-01
WORK="$(mktemp -d "${TMPDIR:-/tmp}/squircle-edge.XXXXXX")"
trap '/usr/bin/trash "$WORK" 2>/dev/null || true' EXIT
"$MAGICK" -size 64x64 xc:white "$WORK/w.png"
"$SQUIRCLE_ROOT/bin/squircle.sh" "$WORK/w.png" --out "$WORK/o.webp" >/dev/null
[[ -f "$WORK/o.webp" ]] && ok "webp written" || bad "webp write"

probe SQ-ENC-01
mkdir -p "$WORK/ünicode"
"$MAGICK" -size 32x32 xc:'#112233' "$WORK/ünicode/tïle.png"
"$SQUIRCLE_ROOT/bin/squircle.sh" "$WORK/ünicode/tïle.png" --out "$WORK/ünicode/out.webp" >/dev/null
[[ -f "$WORK/ünicode/out.webp" ]] && ok "unicode path" || bad "unicode path"

probe SQ-BG-01
"$SQUIRCLE_ROOT/bin/test/squircle-bg-default.regression.sh"
ok "bg-default regression"

probe SQ-AP-01
"$SQUIRCLE_ROOT/bin/test/squircle-padding-aperture.regression.sh"
ok "aperture regression"

probe SQ-ISO-01
ok "bg-default ⊥ aperture (both live PASS)"

probe SQ-BG-02
fn="$(sed -n '/^sample_corner_bg_hex()/,/^}/p' "$SQUIRCLE_ROOT/bin/squircle.sh")"
if print -r -- "$fn" | grep -qE -- '-resize[[:space:]]+64x64'; then
  bad "sample_corner resize-first"
else
  ok "sample_corner no resize-first"
fi

probe SQ-AP-02
grep -q '^aperture_safe_pad()' "$SQUIRCLE_ROOT/bin/squircle.sh" && ok "aperture_safe_pad fn" || bad "aperture_safe_pad missing"
grep -q 'APERTURE_CLEARANCE_PX' "$SQUIRCLE_ROOT/bin/squircle.sh" && ok "APERTURE_CLEARANCE_PX" || bad "clearance const"
grep -q 'DstIn' "$SQUIRCLE_ROOT/bin/squircle.sh" && ok "DstIn transparent margin" || bad "DstIn missing"

probe SQ-SLUG-01
"$SQUIRCLE_ROOT/.hooks/scripts/sluggify-paths.regression.sh"
ok "sluggify webp-only"

probe SQ-CONC-01
"$MAGICK" -size 48x48 xc:red "$WORK/a.png"
"$MAGICK" -size 48x48 xc:blue "$WORK/b.png"
"$SQUIRCLE_ROOT/bin/squircle.sh" "$WORK/a.png" --out "$WORK/a.webp" >/dev/null &
pid_a=$!
"$SQUIRCLE_ROOT/bin/squircle.sh" "$WORK/b.png" --out "$WORK/b.webp" >/dev/null &
pid_b=$!
wait $pid_a; ra=$?
wait $pid_b; rb=$?
(( ra == 0 && rb == 0 )) && [[ -f $WORK/a.webp && -f $WORK/b.webp ]] && ok "parallel renders" || bad "parallel ra=$ra rb=$rb"

print -u2 "squircle-edge-active pass=$pass fail=$fail"
(( fail == 0 ))
exit $?
