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
VARIANT_RE='(-(coding-plan|token-plan|code-plan|step-plan)(-|$))|(-vertex(-|$))|(-cn$)'

shim() {
  >&2 printf '🔴 %s: %s (exit %s)\n  run: %s\n' "$1" "$2" "$3" "$4"
}

[[ -f "$SLUGS" ]] || { shim logo-corpus-write-law "slugs.json missing" 40 "bash $ROOT/test/logo-corpus-slug-law.sh"; exit 40; }
mkdir -p "$LEDGER"
tmp="$(mktemp -t logo-corpus-write-law.XXXXXX)"
jq -r '.slugs[] | select(.in_scope==true) | .slug' "$SLUGS" | sort -u >"$tmp"

variants=0
missing_pass=0

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
  if [[ ! -f "$lf" ]]; then
    missing_pass=$((missing_pass+1))
    continue
  fi
  status="$(jq -r '.verify_status // empty' "$lf")"
  case "$status" in
    pass_authoritative|pass_cluster) ;;
    *) missing_pass=$((missing_pass+1)) ;;
  esac
done

rm -f "$tmp"

if (( variants > 0 )); then
  shim logo-corpus-write-law "$variants variant-SKU files leaked to webp/" 41 \
    "python3 $ROOT/bin/logo-corpus-publish.py --prune-variants"
  exit 41
fi
if (( missing_pass > 0 )); then
  shim logo-corpus-write-law "$missing_pass webp/<slug>.webp without ledger pass_authoritative or pass_cluster" 42 \
    "python3 $ROOT/bin/logo-corpus-fetch.py && python3 $ROOT/bin/logo-corpus-verify.py && python3 $ROOT/bin/logo-corpus-publish.py"
  exit 42
fi

printf 'pass logo-corpus-write-law\n'
