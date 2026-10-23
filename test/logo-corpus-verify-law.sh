#!/usr/bin/env bash
# logo-corpus-verify-law: every in-scope slug has ledger/<slug>.json with a verify_status.
# Winner sha256/phash must not appear in known-bad-anchors.json.
# Exit 0 pass, 30/31/32 violation.
set -u

ROOT="${SQUIRCLE:-$(cd "$(dirname "$0")/.." && pwd)}"
REG="$ROOT/registry/logo-corpus"
SLUGS="$REG/slugs.json"
LEDGER="$REG/ledger"
BAD="$REG/known-bad-anchors.json"

shim() {
  >&2 printf '🔴 %s: %s (exit %s)\n  run: %s\n' "$1" "$2" "$3" "$4"
}

[[ -f "$SLUGS" ]] || { shim logo-corpus-verify-law "slugs.json missing" 30 "bash $ROOT/test/logo-corpus-slug-law.sh"; exit 30; }

missing=0
bad_status=0
bad_hash=0

bad_sha="$(jq -r '.sha256[]?' "$BAD" 2>/dev/null)"

while IFS= read -r slug; do
  f="$LEDGER/$slug.json"
  if [[ ! -f "$f" ]]; then
    missing=$((missing+1))
    continue
  fi
  status="$(jq -r '.verify_status // empty' "$f")"
  if [[ -z "$status" ]]; then
    bad_status=$((bad_status+1))
    continue
  fi
  if [[ "$status" == pass ]]; then
    winner_sha="$(jq -r '.winner_sha256 // empty' "$f")"
    if [[ -n "$winner_sha" ]] && [[ -n "$bad_sha" ]] && grep -qxF "$winner_sha" <<<"$bad_sha"; then
      >&2 printf '    known-bad winner sha256 in %s: %s\n' "$f" "$winner_sha"
      bad_hash=$((bad_hash+1))
    fi
  fi
done < <(jq -r '.slugs[] | select(.in_scope==true) | .slug' "$SLUGS")

if (( bad_hash > 0 )); then
  shim logo-corpus-verify-law "$bad_hash winners match known-bad-anchors" 31 \
    "edit $REG/known-bad-anchors.json; re-run $ROOT/bin/logo-corpus-fetch.py --slug <slug>"
  exit 31
fi
if (( bad_status > 0 )); then
  shim logo-corpus-verify-law "$bad_status ledger rows missing verify_status" 32 \
    "python3 $ROOT/bin/logo-corpus-verify.py"
  exit 32
fi
if (( missing > 0 )); then
  shim logo-corpus-verify-law "$missing in-scope slugs have no ledger row" 32 \
    "python3 $ROOT/bin/logo-corpus-verify.py"
  exit 32
fi

printf 'pass logo-corpus-verify-law\n'
