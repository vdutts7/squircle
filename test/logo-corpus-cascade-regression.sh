#!/usr/bin/env bash
# End-to-end cascade regression: 10 pinned brands must each produce a pass_* ledger
# AND a webp/<slug>.webp file. Exits non-zero on any miss.
set -u
ROOT="${SQUIRCLE:-$(cd "$(dirname "$0")/.." && pwd)}"
PY="$ROOT/bin/.venv/bin/python3"

BRANDS=(anthropic openai google nvidia meta cohere mistral deepseek nebius openrouter)

echo "— cascade regression on ${#BRANDS[@]} pinned brands —"
"$PY" "$ROOT/bin/logo-corpus-fetch.py" "${BRANDS[@]}" --parallel 8 >/dev/null 2>&1 || true
"$PY" "$ROOT/bin/logo-corpus-verify.py" "${BRANDS[@]}" >/dev/null 2>&1 || true
"$PY" "$ROOT/bin/logo-corpus-publish.py" >/dev/null 2>&1 || true

pass=0; fail=0
for slug in "${BRANDS[@]}"; do
  lf="$ROOT/registry/logo-corpus/ledger/$slug.json"
  wf="$ROOT/webp/$slug.webp"
  status="$(jq -r '.verify_status // empty' "$lf" 2>/dev/null)"
  if [[ "$status" == pass_authoritative || "$status" == pass_cluster ]] && [[ -s "$wf" ]]; then
    winner="$(jq -r '.winner_source // ""' "$lf")"
    pass=$((pass+1))
    printf '🟢 %-14s %s winner=%s\n' "$slug" "$status" "$winner"
  else
    fail=$((fail+1))
    printf '🔴 %-14s status=%s webp=%s\n' "$slug" "${status:-NONE}" "$([[ -s $wf ]] && echo yes || echo no)"
  fi
done
printf -- '--- pass=%s fail=%s ---\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
