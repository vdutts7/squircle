#!/usr/bin/env bash
# logo-corpus-write-law: every webp/<slug>.webp whose <slug> is in slugs.json must have
# ledger pass + eyeball approved. Variant SKUs must not exist (overlaps slug-law, kept
# here so this gate is standalone-sufficient).
# Exit 0 pass, 40/41/42 violation.
set -u

ROOT="${SQUIRCLE:-$(cd "$(dirname "$0")/.." && pwd)}"
REG="$ROOT/registry/logo-corpus"
SLUGS="$REG/slugs.json"
LEDGER="$REG/ledger"
EYE="$REG/eyeball.json"
VARIANT_RE='(-(coding-plan|token-plan|code-plan)(-|$))|(-vertex(-|$))|(-cn$)'

shim() {
  >&2 printf '🔴 %s: %s (exit %s)\n  run: %s\n' "$1" "$2" "$3" "$4"
}

[[ -f "$SLUGS" ]] || { shim logo-corpus-write-law "slugs.json missing" 40 "bash $ROOT/test/logo-corpus-slug-law.sh"; exit 40; }
[[ -f "$EYE"   ]] || { shim logo-corpus-write-law "eyeball.json missing" 40 "git -C $ROOT checkout -- registry/logo-corpus/eyeball.json"; exit 40; }

tmp="$(mktemp -t logo-corpus-write-law.XXXXXX)"
jq -r '.slugs[] | select(.in_scope==true) | .slug' "$SLUGS" | sort -u >"$tmp"

variants=0
missing_ledger=0
missing_eye=0

for f in "$ROOT"/webp/*.webp; do
  [[ -e "$f" ]] || break
  stem="$(basename "$f" .webp)"
  if [[ "$stem" =~ $VARIANT_RE ]]; then
    variants=$((variants+1))
    continue
  fi
  if ! grep -qxF "$stem" "$tmp"; then
    continue
  fi
  lf="$LEDGER/$stem.json"
  if [[ ! -f "$lf" ]] || [[ "$(jq -r '.verify_status // empty' "$lf")" != pass ]]; then
    missing_ledger=$((missing_ledger+1))
    continue
  fi
  v="$(jq -r --arg s "$stem" '.slugs[$s].human_verdict // empty' "$EYE")"
  if [[ "$v" != approved ]]; then
    missing_eye=$((missing_eye+1))
  fi
done

rm -f "$tmp"

if (( variants > 0 )); then
  shim logo-corpus-write-law "$variants variant-SKU files leaked to webp/" 41 \
    "python3 $ROOT/bin/logo-corpus-publish.py --prune-variants"
  exit 41
fi
if (( missing_ledger > 0 )); then
  shim logo-corpus-write-law "$missing_ledger webp/<slug>.webp without ledger pass" 42 \
    "python3 $ROOT/bin/logo-corpus-verify.py"
  exit 42
fi
if (( missing_eye > 0 )); then
  shim logo-corpus-write-law "$missing_eye webp/<slug>.webp without eyeball approved" 42 \
    "python3 $ROOT/bin/logo-corpus-review.py"
  exit 42
fi

printf 'pass logo-corpus-write-law\n'
