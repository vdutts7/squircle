#!/usr/bin/env bash
set -euo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
CURREGISTRY="${CURREGISTRY:-$HOME/.cursor/registry}"
CORPUS="${SQUIRCLE_RENDER_CSP_CORPUS:-$CURREGISTRY/squircle/render-csp/corpus/corpus.json}"
PLAN_PY="$BIN/squircle-render-plan.py"
SQUIRCLE_SH="$BIN/squircle.sh"
SAMPLE="${SQUIRCLE_CORPUS_SAMPLE:-0}"

pass=0
fail=0
ran=0
bad() { echo "  FAIL $1" >&2; fail=$((fail + 1)); }

[[ -f "$CORPUS" ]] || { echo "missing corpus — run: python3 $BIN/squircle-render-csp-corpus-fetch.py" >&2; exit 2; }

export SQUIRCLE="$ROOT"
export CURREGISTRY
WORK="$(mktemp -d "${TMPDIR:-/tmp}/squircle-corpus-regr.XXXXXX")"
CASES_TSV="$WORK/cases.jsonl"
trap 'rm -rf "$WORK"' EXIT

python3 - "$CORPUS" "$SAMPLE" "$CASES_TSV" <<'PY'
import json, os, random, sys
corpus = json.load(open(sys.argv[1]))
sample = int(sys.argv[2])
out_path = sys.argv[3]
entries = corpus["entries"]
if sample > 0 and sample < len(entries):
    random.seed(42)
    entries = random.sample(entries, sample)
with open(out_path, "w") as f:
    for e in entries:
        f.write(json.dumps(e) + "\n")
PY

while IFS= read -r case_json; do
  [[ -n "$case_json" ]] || continue
  ran=$((ran + 1))
  cid=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$case_json")
  inp=$(python3 -c 'import json,os,sys; e=json.loads(sys.argv[1]); print(os.path.expandvars(e["local"].replace("$CURREGISTRY", os.environ["CURREGISTRY"])))' "$case_json")
  [[ -f "$inp" ]] || { bad "$cid missing $inp"; continue; }
  out="$WORK/${cid}.webp"
  plan_pre="$WORK/${cid}.plan.json"
  python3 "$PLAN_PY" "$inp" >"$plan_pre" || { bad "$cid plan"; continue; }
  export SQUIRCLE_PLAN_SNAPSHOT="$plan_pre"
  if SQUIRCLE_AUTO_PLAN=1 SQUIRCLE_POSTCHECK=1 "$SQUIRCLE_SH" "$inp" --out "$out" >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    bad "$cid render"
  fi
done <"$CASES_TSV"

total=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["entries"]))' "$CORPUS")
echo "squircle-render-csp-corpus pass=$pass fail=$fail corpus=$total ran=$ran sample=${SAMPLE:-all}" >&2
[[ "$fail" -eq 0 ]]
