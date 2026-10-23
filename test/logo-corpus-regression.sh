#!/usr/bin/env bash
# logo-corpus.regression: run every logo-corpus gate; aggregate; exit non-zero on any fail.
set -u

ROOT="${SQUIRCLE:-$(cd "$(dirname "$0")/.." && pwd)}"
GATES=(
  "$ROOT/test/logo-corpus-slug-law.sh"
  "$ROOT/test/logo-corpus-source-law.sh"
  "$ROOT/test/logo-corpus-verify-law.sh"
  "$ROOT/test/logo-corpus-write-law.sh"
)

pass=0
fail=0
failed_gates=()
for g in "${GATES[@]}"; do
  if bash "$g"; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    failed_gates+=("$g")
  fi
done

printf '— logo-corpus regression: pass=%s fail=%s —\n' "$pass" "$fail"
if (( fail > 0 )); then
  for g in "${failed_gates[@]}"; do printf '  FAIL %s\n' "$g"; done
  exit 1
fi
