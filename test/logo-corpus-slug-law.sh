#!/usr/bin/env bash
# logo-corpus-slug-law: gate on slugs.json presence + variant-SKU leak in webp/.
# Exit 0 pass, 10/11/12 violation. Stderr emits exact fix.
set -u

ROOT="${SQUIRCLE:-$(cd "$(dirname "$0")/.." && pwd)}"
REG="$ROOT/registry/logo-corpus"
SLUGS="$REG/slugs.json"
VARIANT_RE='(-(coding-plan|token-plan|code-plan)(-|$))|(-vertex(-|$))|(-cn$)'

shim() { # tool violation exit redirect
  >&2 printf '🔴 %s: %s (exit %s)\n  run: %s\n' "$1" "$2" "$3" "$4"
}

if [[ ! -f "$SLUGS" ]]; then
  shim logo-corpus-slug-law "slugs.json missing" 10 \
    "python3 $ROOT/bin/logo-corpus-build-slugs.py"
  exit 10
fi

if ! command -v jq >/dev/null; then
  shim logo-corpus-slug-law "jq not installed" 11 "brew install jq"
  exit 11
fi

if ! jq -e '.slugs | type == "array"' "$SLUGS" >/dev/null 2>&1; then
  shim logo-corpus-slug-law "slugs.json schema invalid" 11 \
    "python3 $ROOT/bin/logo-corpus-build-slugs.py"
  exit 11
fi

leaks=()
while IFS= read -r f; do
  stem="$(basename "$f" .webp)"
  if [[ "$stem" =~ $VARIANT_RE ]]; then
    leaks+=("$f")
  fi
done < <(find "$ROOT/webp" -maxdepth 1 -type f -name '*.webp' 2>/dev/null)

if (( ${#leaks[@]} > 0 )); then
  >&2 printf '🔴 logo-corpus-slug-law: %s variant-SKU files leaked into webp/ (exit 12)\n' "${#leaks[@]}"
  for f in "${leaks[@]}"; do >&2 printf '    %s\n' "$f"; done
  >&2 printf '  run: python3 %s/bin/logo-corpus-publish.py --prune-variants\n' "$ROOT"
  exit 12
fi

printf 'pass logo-corpus-slug-law (slugs=%s)\n' \
  "$(jq '.slugs | length' "$SLUGS")"
