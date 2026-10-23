#!/usr/bin/env bash
# Tier 4 models.dev clone — 5 pinned brands expected to all pass.
set -u
ROOT="${SQUIRCLE:-$(cd "$(dirname "$0")/.." && pwd)}"
PY="$ROOT/bin/.venv/bin/python3"
SCRIPT="$ROOT/bin/sources/models_dev.py"
BRANDS=(anthropic openai google nvidia meta)
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lc-md-smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
for slug in "${BRANDS[@]}"; do
  out="$TMP/$slug"; mkdir -p "$out"
  "$PY" "$SCRIPT" "$slug" --out-dir "$out" 2>/dev/null
  f=$(/bin/ls -1 "$out" 2>/dev/null | grep -v meta.json | head -n1)
  if [[ -n "$f" ]]; then
    sz=$(wc -c <"$out/$f")
    (( sz > 100 )) && { pass=$((pass+1)); printf '🟢 models_dev %s bytes=%s\n' "$slug" "$sz"; continue; }
  fi
  fail=$((fail+1)); printf '🔴 models_dev %s FAIL\n' "$slug"
done
printf -- '--- pass=%s fail=%s ---\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
