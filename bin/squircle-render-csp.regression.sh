#!/usr/bin/env bash
# render CSP regression — fetch public fixtures ($CURREGISTRY), plan, render, verify constraints.
set -euo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
CURREGISTRY="${CURREGISTRY:-$HOME/.cursor/registry}"
FIXTURES="${SQUIRCLE_RENDER_CSP_FIXTURES:-$CURREGISTRY/squircle/render-csp/fixtures.json}"
PLAN_PY="$BIN/squircle-render-plan.py"
VERIFY_PY="$BIN/squircle-render-csp-verify.py"
SQUIRCLE_SH="$BIN/squircle.sh"

pass=0
fail=0
ok() { echo "  ok $1" >&2; pass=$((pass + 1)); }
bad() { echo "  FAIL $1" >&2; fail=$((fail + 1)); }

[[ -f "$FIXTURES" ]] || { bad "missing fixtures registry $FIXTURES"; exit 2; }
[[ -x "$SQUIRCLE_SH" ]] || { bad "missing squircle.sh"; exit 2; }
[[ -f "$PLAN_PY" ]] || { bad "missing squircle-render-plan.py"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/squircle-csp-regr.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

export SQUIRCLE="$ROOT"
export MAGICK="${MAGICK:-/opt/homebrew/bin/magick}"
[[ -x "$MAGICK" ]] || MAGICK=/usr/local/bin/magick

case_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["cases"]))' "$FIXTURES")

while IFS= read -r case_json; do
  cid=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$case_json")
  url=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["url"])' "$case_json")
  inp="$WORK/${cid}.in.png"
  out="$WORK/${cid}.webp"
  plan_out="$WORK/${cid}.plan.json"

  if ! curl -fsSL --max-time 60 -o "$inp" "$url"; then
    bad "$cid fetch"
    continue
  fi
  ok "$cid fetch"

  if ! python3 "$PLAN_PY" "$inp" >"$plan_out"; then
    bad "$cid plan"
    continue
  fi
  ok "$cid plan"

  if ! SQUIRCLE_AUTO_PLAN=1 "$SQUIRCLE_SH" "$inp" --out "$out" >/dev/null 2>&1; then
    bad "$cid render"
    continue
  fi
  ok "$cid render"

  expect_json=$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["expect"]))' "$case_json")
  if python3 "$VERIFY_PY" "$expect_json" "$plan_out" "$out"; then
    ok "$cid verify"
  else
    bad "$cid verify"
  fi
done < <(python3 -c 'import json,sys; [print(json.dumps(c)) for c in json.load(open(sys.argv[1]))["cases"]]' "$FIXTURES")

echo "squircle-render-csp.regression pass=$pass fail=$fail cases=$case_count" >&2
[[ "$fail" -eq 0 ]]
