#!/usr/bin/env bash
# Repo-native verify runner (execution plane). No $CURTOOLS required.
# Reads bin/test/tests.json + bin/test/edge-case-matrix.json (data plane).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export SQUIRCLE="${SQUIRCLE:-$ROOT}"
MATRIX="$SQUIRCLE/bin/test/edge-case-matrix.json"
TESTS="$SQUIRCLE/bin/test/tests.json"

pass=0
fail=0
ok() { echo "  ok $1" >&2; pass=$((pass + 1)); }
bad() { echo "  FAIL $1" >&2; fail=$((fail + 1)); }

[[ -f "$MATRIX" ]] || { bad "missing $MATRIX"; exit 2; }
[[ -f "$TESTS" ]] || { bad "missing $TESTS"; exit 2; }
ok "bin/test registry data present"

# Lyapunov L: gap/deferred/incomplete covered → fail closed
L="$(python3 - "$MATRIX" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
cases = m.get("cases") or []
L = 0
for c in cases:
    st = c.get("status")
    if st in ("gap", "deferred") or st != "covered":
        L += 1
    elif not c.get("suite") or not c.get("probe"):
        L += 1
print(L)
PY
)"
echo "L=$L" >&2
(( L == 0 )) && ok "matrix L=0" || bad "matrix L=$L"

# Run each active module from tests.json (relative to repo root)
while IFS= read -r script; do
  [[ -z "$script" ]] && continue
  path="$SQUIRCLE/$script"
  echo "══ module: $script ══" >&2
  if [[ -x "$path" ]] && "$path"; then
    ok "$script"
  else
    bad "$script"
  fi
done < <(python3 - "$TESTS" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for mod in m.get("modules") or []:
    s = mod.get("script")
    if s:
        print(s)
PY
)

echo "run-all pass=$pass fail=$fail" >&2
(( fail == 0 ))
exit $?
