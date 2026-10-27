#!/usr/bin/env bash
# PARITY: C-SILHOUETTE — opaque alpha matches mask silhouette (not inset rectangle).
# Bound to: registry/contracts/silhouette.json
# Isolation: does NOT assert margin hex, letterbox RGB, or aperture ink gaps.
# Locks: 1e986bcc none + eceff6cc DstIn → constant opaque row width (easyoptouts-class).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SQUIRCLE_SH="${SQUIRCLE_SH:-$ROOT/bin/squircle.sh}"
MASK="${MASK:-$ROOT/bin/mask.png}"
CONTRACT="$ROOT/registry/contracts/silhouette.json"
MAGICK="${MAGICK:-/opt/homebrew/bin/magick}"
[[ -x "$MAGICK" ]] || MAGICK=/usr/local/bin/magick

pass=0
fail=0
ok() { echo "  ok $1" >&2; pass=$((pass + 1)); }
bad() { echo "  FAIL $1" >&2; fail=$((fail + 1)); }

[[ -x "$SQUIRCLE_SH" ]] || { bad "squircle.sh missing"; exit 2; }
[[ -f "$MASK" ]] || { bad "mask.png missing"; exit 2; }
[[ -f "$CONTRACT" ]] || { bad "silhouette contract missing"; exit 2; }
[[ -x "$MAGICK" ]] || { bad "magick missing"; exit 2; }
ok "binaries+contract"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/squircle-sil-regr.XXXXXX")"
cleanup() { /usr/bin/trash "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# High-chroma landscape tile (easyoptouts-class). No fonts — pure field.
FIX="$WORK/teal-landscape.png"
"$MAGICK" -size 620x325 xc:'#76F8E5' "$FIX"
ok "fixture teal-landscape"

OUT="$WORK/out.webp"
set +e
status="$("$SQUIRCLE_SH" "$FIX" --out "$OUT" 2>&1)"
rc=$?
set -e
echo "$status" >&2
(( rc == 0 )) && ok "squircle exit 0" || bad "squircle exit $rc"
[[ -f "$OUT" ]] && ok "webp written" || bad "webp missing"

python3 - "$OUT" "$MASK" "$CONTRACT" <<'PY'
import json, subprocess, sys
from pathlib import Path

out, mask_path, contract_path = sys.argv[1:4]
c = json.loads(Path(contract_path).read_text())
g = c["gates"]
SIZE = 1024
magick = "/opt/homebrew/bin/magick"
import os
if not os.path.isfile(magick):
    magick = "/usr/local/bin/magick"

def run(*args):
    return subprocess.check_output([magick, *args], stderr=subprocess.DEVNULL)

rgba = run(out, "-depth", "8", "rgba:-")
mask = run(
    mask_path, "-resize", f"{SIZE}x{SIZE}",
    "-alpha", "extract", "-threshold", "50%", "-depth", "8", "gray:-",
)

def a_at(x, y):
    return rgba[(y * SIZE + x) * 4 + 3]

def mv(x, y):
    return mask[y * SIZE + x]

widths = []
opaque = 0
for y in range(SIZE):
    xs = [x for x in range(SIZE) if a_at(x, y) > 0]
    if xs:
        widths.append(xs[-1] - xs[0] + 1)
        opaque += len(xs)

mask_opaque = sum(1 for y in range(SIZE) for x in range(SIZE) if mv(x, y) > 127)
uniq = len(set(widths))
print(f"opaque={opaque} mask_opaque={mask_opaque} unique_widths={uniq}", file=sys.stderr)

rc = 0
# Explicit anti-regression: constant width == inset rectangle (DstIn/none bug).
if uniq == 1:
    print(f"FAIL unique_widths=1 (axis-aligned rect; none+DstIn regression)", file=sys.stderr)
    rc = 2

min_u = int(g["min_unique_opaque_row_widths"])
if uniq < min_u:
    print(f"FAIL unique_widths {uniq} < {min_u} (rectangle silhouette)", file=sys.stderr)
    rc = 2
else:
    print(f"ok unique_widths {uniq} >= {min_u}", file=sys.stderr)

rel = abs(opaque - mask_opaque) / max(mask_opaque, 1)
lim = float(g["opaque_count_vs_mask_rel_err_max"])
if rel > lim:
    print(f"FAIL opaque_vs_mask rel_err {rel:.4f} > {lim}", file=sys.stderr)
    rc = 2
else:
    print(f"ok opaque_vs_mask rel_err {rel:.4f}", file=sys.stderr)

if g.get("require_mid_width_gt_edge_width") and widths:
    edge = (widths[0] + widths[-1]) / 2
    mid = widths[len(widths) // 2]
    if mid <= edge:
        print(f"FAIL mid_width {mid} <= edge_avg {edge} (not squircle curve)", file=sys.stderr)
        rc = 2
    else:
        print(f"ok mid_width {mid} > edge_avg {edge}", file=sys.stderr)

sys.exit(rc)
PY
py_rc=$?
(( py_rc == 0 )) && ok "C-SILHOUETTE gates" || bad "C-SILHOUETTE gates"

echo "squircle-silhouette.regression pass=$pass fail=$fail" >&2
(( fail == 0 ))
exit $?
