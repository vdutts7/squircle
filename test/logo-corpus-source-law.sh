#!/usr/bin/env bash
# logo-corpus-source-law: every in-scope slug has raw/<slug>/ with an artifact or FAIL.json.
# No source kind outside sources.json#kinds_enum.
# Exit 0 pass, 20/21/22 violation.
set -u

ROOT="${SQUIRCLE:-$(cd "$(dirname "$0")/.." && pwd)}"
REG="$ROOT/registry/logo-corpus"
SLUGS="$REG/slugs.json"
SOURCES="$REG/sources.json"
RAW="$REG/raw"

shim() {
  >&2 printf '🔴 %s: %s (exit %s)\n  run: %s\n' "$1" "$2" "$3" "$4"
}

[[ -f "$SLUGS"   ]] || { shim logo-corpus-source-law "slugs.json missing"   20 "bash $ROOT/test/logo-corpus-slug-law.sh"; exit 20; }
[[ -f "$SOURCES" ]] || { shim logo-corpus-source-law "sources.json missing" 20 "git -C $ROOT checkout -- registry/logo-corpus/sources.json"; exit 20; }

enum="$(jq -r '.kinds_enum[]' "$SOURCES")"
missing=0
bad_kind=0

while IFS= read -r slug; do
  d="$RAW/$slug"
  if [[ ! -d "$d" ]]; then
    missing=$((missing+1))
    continue
  fi
  arts=0
  for f in "$d"/*; do
    [[ -e "$f" ]] || continue
    bn="$(basename "$f")"
    [[ "$bn" == FAIL.json ]] && { arts=1; continue; }
    [[ "$bn" == *.meta.json ]] && continue
    # Expect <NN>-<kind>.<ext>  →  strip NN- prefix and .<ext> suffix (first dot)
    kind="$(printf '%s' "$bn" | sed -E 's/^[0-9]+-//; s/\..*$//')"
    if ! grep -qxF "$kind" <<<"$enum"; then
      >&2 printf '    illegal source kind: %s in %s\n' "$kind" "$f"
      bad_kind=$((bad_kind+1))
    fi
    arts=1
  done
  (( arts == 0 )) && missing=$((missing+1))
done < <(jq -r '.slugs[] | select(.in_scope==true) | .slug' "$SLUGS")

if (( bad_kind > 0 )); then
  shim logo-corpus-source-law "$bad_kind files use kinds outside sources.json#kinds_enum" 21 \
    "edit $REG/sources.json or rename the offending raw/* files"
  exit 21
fi

if (( missing > 0 )); then
  shim logo-corpus-source-law "$missing in-scope slugs have no raw/<slug>/ artifacts" 22 \
    "python3 $ROOT/bin/logo-corpus-fetch.py"
  exit 22
fi

printf 'pass logo-corpus-source-law\n'
