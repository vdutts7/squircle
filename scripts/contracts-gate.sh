#!/usr/bin/env bash
# Gate: registry contracts are complete, wired to scripts, assert_dimensions pairwise disjoint.
# FAIL CLOSED on overlap (whack-a-mole) or missing suite script.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/registry/manifest.json"
FEATURES="$ROOT/registry/features.json"

pass=0
fail=0
ok() { echo "  ok $1" >&2; pass=$((pass + 1)); }
bad() { echo "  FAIL $1" >&2; fail=$((fail + 1)); }

[[ -f "$MANIFEST" ]] || { bad "missing $MANIFEST"; exit 2; }
[[ -f "$FEATURES" ]] || { bad "missing $FEATURES"; exit 2; }
ok "registry manifest+features"

python3 - "$ROOT" "$MANIFEST" "$FEATURES" <<'PY' || exit 2
import json, sys
from pathlib import Path
from collections import defaultdict

root = Path(sys.argv[1])
manifest = json.loads(Path(sys.argv[2]).read_text())
features = json.loads(Path(sys.argv[3]).read_text())
fail = 0

def bad(msg):
    global fail
    print(f"  FAIL {msg}", file=sys.stderr)
    fail += 1

def ok(msg):
    print(f"  ok {msg}", file=sys.stderr)

contracts = []
for rel in manifest.get("contracts") or []:
    p = root / rel
    if not p.is_file():
        bad(f"missing contract {rel}")
        continue
    c = json.loads(p.read_text())
    contracts.append(c)
    script = c.get("script")
    if not script or not (root / script).is_file():
        bad(f"{c.get('id')} missing script {script}")
    else:
        ok(f"{c.get('id')} script present")
    dims = c.get("assert_dimensions") or []
    if not dims:
        bad(f"{c.get('id')} empty assert_dimensions")

# pairwise disjoint assert_dimensions
owner = {}
for c in contracts:
    for d in c.get("assert_dimensions") or []:
        if d in owner:
            bad(f"assert_dimension overlap: {d} owned by {owner[d]} and {c['id']}")
        else:
            owner[d] = c["id"]
if fail == 0:
    ok(f"assert_dimensions disjoint (n={len(owner)})")

# feature → primary contract exists
ids = {c["id"] for c in contracts}
for f in features.get("features") or []:
    prim = f.get("primary_contract")
    if prim not in ids:
        bad(f"feature {f.get('id')} primary_contract {prim} missing")
    else:
        ok(f"feature {f.get('id')} → {prim}")
    for s in f.get("supporting") or []:
        if s not in ids:
            bad(f"feature {f.get('id')} supporting {s} missing")

# forbidden: a contract must not list its own asserts as forbidden
for c in contracts:
    a = set(c.get("assert_dimensions") or [])
    fbd = set(c.get("forbidden_dimensions") or [])
    hit = a & fbd
    if hit:
        bad(f"{c['id']} asserts∩forbidden={hit}")

sys.exit(2 if fail else 0)
PY
gate_rc=$?
(( gate_rc == 0 )) && ok "python contracts ontology" || bad "python contracts ontology"

echo "contracts-gate pass=$pass fail=$fail" >&2
(( fail == 0 ))
exit $?
