#!/usr/bin/env bash
# Twitter microservice smoke — 5 pinned brands.
set -u
ROOT="${SQUIRCLE:-$(cd "$(dirname "$0")/.." && pwd)}"
PY="$ROOT/bin/.venv/bin/python3"
SCRIPT="$ROOT/bin/sources/twitter.py"
BRANDS=(anthropic openai google nvidia meta)
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lc-tw-smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
for slug in "${BRANDS[@]}"; do
  out="$TMP/$slug"; mkdir -p "$out"
  if "$PY" "$SCRIPT" "$slug" --out-dir "$out" 2>/dev/null; then
    f=$(/bin/ls -1 "$out" 2>/dev/null | grep -v meta.json | head -n1)
    if [[ -n "$f" ]]; then
      sz=$(wc -c <"$out/$f")
      handle=$(jq -r '.handle' "$out/$f.meta.json")
      if (( sz > 300 )); then
        pass=$((pass+1))
        printf '🟢 twitter %s bytes=%s handle=@%s\n' "$slug" "$sz" "$handle"
        continue
      fi
    fi
  fi
  fail=$((fail+1))
  printf '🔴 twitter %s FAIL\n' "$slug"
done
printf -- '--- pass=%s fail=%s ---\n' "$pass" "$fail"
(( pass >= 4 )) || exit 1
