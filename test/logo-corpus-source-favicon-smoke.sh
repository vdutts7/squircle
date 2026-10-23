#!/usr/bin/env bash
# Tier 5 favicon stack — 5 pinned brands expected to pass (threshold >=4).
set -u
ROOT="${SQUIRCLE:-$(cd "$(dirname "$0")/.." && pwd)}"
PY="$ROOT/bin/.venv/bin/python3"
SCRIPT="$ROOT/bin/sources/favicon.py"
BRANDS=(anthropic openai google nvidia meta)
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lc-fv-smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
for slug in "${BRANDS[@]}"; do
  out="$TMP/$slug"; mkdir -p "$out"
  "$PY" "$SCRIPT" "$slug" --out-dir "$out" 2>/dev/null
  f=$(/bin/ls -1 "$out" 2>/dev/null | grep -v meta.json | head -n1)
  if [[ -n "$f" ]]; then
    sz=$(wc -c <"$out/$f")
    host=$(jq -r '.host' "$out/$f.meta.json" 2>/dev/null)
    (( sz > 500 )) && { pass=$((pass+1)); printf '🟢 favicon %s bytes=%s host=%s\n' "$slug" "$sz" "$host"; continue; }
  fi
  fail=$((fail+1)); printf '🟡 favicon %s MISS\n' "$slug"
done
printf -- '--- pass=%s fail=%s (threshold >=4) ---\n' "$pass" "$fail"
(( pass >= 4 )) || exit 1
