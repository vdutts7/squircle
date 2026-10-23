#!/usr/bin/env bash
# GitHub microservice smoke — 5 pinned brands; not every brand has an org, so threshold is >=3.
set -u
ROOT="${SQUIRCLE:-$(cd "$(dirname "$0")/.." && pwd)}"
PY="$ROOT/bin/.venv/bin/python3"
SCRIPT="$ROOT/bin/sources/github.py"
BRANDS=(anthropic openai google nvidia meta)
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lc-gh-smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
for slug in "${BRANDS[@]}"; do
  out="$TMP/$slug"; mkdir -p "$out"
  if "$PY" "$SCRIPT" "$slug" --out-dir "$out" 2>/dev/null; then
    f=$(/bin/ls -1 "$out" 2>/dev/null | grep -v meta.json | head -n1)
    if [[ -n "$f" ]]; then
      sz=$(wc -c <"$out/$f")
      login=$(jq -r '.login' "$out/$f.meta.json")
      if (( sz > 500 )); then
        pass=$((pass+1))
        printf '🟢 github %s bytes=%s login=%s\n' "$slug" "$sz" "$login"
        continue
      fi
    fi
  fi
  fail=$((fail+1))
  printf '🟡 github %s MISS\n' "$slug"
done
printf -- '--- pass=%s fail=%s (threshold >=3) ---\n' "$pass" "$fail"
(( pass >= 3 )) || exit 1
