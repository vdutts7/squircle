#!/usr/bin/env bash
# PARITY: C-EXPLICIT-PADDING — --padding N in status; silhouette intact.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SQUIRCLE_SH="${SQUIRCLE_SH:-$ROOT/bin/squircle.sh}"
MASK="${MASK:-$ROOT/bin/mask.png}"
CONTRACT="$ROOT/registry/contracts/explicit-padding.json"
MAGICK="${MAGICK:-/opt/homebrew/bin/magick}"
[[ -x "$MAGICK" ]] || MAGICK=/usr/local/bin/magick
pass=0; fail=0
ok(){ echo "  ok $1" >&2; pass=$((pass+1)); }
bad(){ echo "  FAIL $1" >&2; fail=$((fail+1)); }
[[ -x "$SQUIRCLE_SH" && -f "$MASK" && -f "$CONTRACT" && -x "$MAGICK" ]] || { bad "prereqs"; exit 2; }
ok "prereqs"
PAD="$(python3 -c "import json;print(json.load(open('$CONTRACT'))['gates']['padding_px'])")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/squircle-epad-regr.XXXXXX")"
trap '/usr/bin/trash "$WORK" 2>/dev/null || true' EXIT
FIX="$WORK/plate.png"; OUT="$WORK/out.webp"
"$MAGICK" -size 400x400 xc:'#2288AA' "$FIX"
status="$("$SQUIRCLE_SH" "$FIX" --padding "$PAD" --out "$OUT" 2>&1)" || { bad "exit"; echo "$status" >&2; exit 2; }
echo "$status" >&2
echo "$status" | grep -q "padding ${PAD}px" && ok "padding ${PAD}px honored" || bad "padding not in status: $status"
python3 - "$OUT" "$MASK" "$CONTRACT" <<'PY'
import json, subprocess, sys
from pathlib import Path
out, mask_path, contract = sys.argv[1:4]
g = json.loads(Path(contract).read_text())["gates"]
SIZE=1024
magick="/opt/homebrew/bin/magick"
import os
if not os.path.isfile(magick): magick="/usr/local/bin/magick"
rgba=subprocess.check_output([magick,out,"-depth","8","rgba:-"],stderr=subprocess.DEVNULL)
mask=subprocess.check_output([magick,mask_path,"-resize",f"{SIZE}x{SIZE}","-alpha","extract","-threshold","50%","-depth","8","gray:-"],stderr=subprocess.DEVNULL)
opaque=sum(1 for i in range(0,len(rgba),4) if rgba[i+3]>0)
mask_o=sum(1 for b in mask if b>127)
rel=abs(opaque-mask_o)/max(mask_o,1)
lim=float(g["opaque_count_vs_mask_rel_err_max"])
print(f"opaque={opaque} mask={mask_o} rel={rel:.4f}", file=sys.stderr)
sys.exit(0 if rel<=lim else 2)
PY
(( $? == 0 )) && ok "epad opaque≈mask" || bad "epad opaque≠mask"
echo "squircle-explicit-padding.regression pass=$pass fail=$fail" >&2
(( fail == 0 ))
