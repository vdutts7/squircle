#!/usr/bin/env bash
# Wikipedia microservice smoke — 5 pinned brands.
# Each must: exit 0, write 1 candidate, bytes > 500, distinct sha256.
set -u

ROOT="${SQUIRCLE:-$(cd "$(dirname "$0")/.." && pwd)}"
PY="$ROOT/bin/.venv/bin/python3"
SCRIPT="$ROOT/bin/sources/wikipedia.py"

BRANDS=(anthropic openai google nvidia meta)
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lc-wiki-smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
declare -a hashes=()

for slug in "${BRANDS[@]}"; do
  out="$TMP/$slug"
  mkdir -p "$out"
  if "$PY" "$SCRIPT" "$slug" --out-dir "$out" 2>/dev/null; then
    f=$(/bin/ls -1 "$out" 2>/dev/null | grep -v meta.json | head -n1)
    if [[ -n "$f" ]]; then
      sz=$(wc -c <"$out/$f")
      if (( sz > 500 )); then
        sha=$(shasum -a 256 "$out/$f" | awk '{print $1}')
        hashes+=("$sha")
        pass=$((pass + 1))
        printf '🟢 wikipedia %s bytes=%s sha=%s\n' "$slug" "$sz" "${sha:0:16}"
        continue
      fi
    fi
  fi
  fail=$((fail + 1))
  printf '🔴 wikipedia %s FAIL\n' "$slug"
done

uniq_sha=$(printf '%s\n' "${hashes[@]}" | sort -u | wc -l | tr -d ' ')
if (( uniq_sha != pass )); then
  printf '🔴 wikipedia: %s candidates but only %s distinct sha256 (duplicates = placeholder)\n' "$pass" "$uniq_sha"
  exit 1
fi

printf -- '--- pass=%s fail=%s unique_sha=%s ---\n' "$pass" "$fail" "$uniq_sha"
(( fail == 0 )) || exit 1
