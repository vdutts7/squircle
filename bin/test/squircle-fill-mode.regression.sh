#!/usr/bin/env bash
# PARITY: C-FILL-MODE — --no-clip-detect fill still matches mask silhouette.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SQUIRCLE_SH="${SQUIRCLE_SH:-$ROOT/bin/squircle.sh}"
MASK="${MASK:-$ROOT/bin/mask.png}"
CONTRACT="$ROOT/registry/contracts/fill-mode.json"
MAGICK="${MAGICK:-/opt/homebrew/bin/magick}"
[[ -x "$MAGICK" ]] || MAGICK=/usr/local/bin/magick
pass=0; fail=0
ok(){ echo "  ok $1" >&2; pass=$((pass+1)); }
bad(){ echo "  FAIL $1" >&2; fail=$((fail+1)); }
[[ -x "$SQUIRCLE_SH" && -f "$MASK" && -f "$CONTRACT" && -x "$MAGICK" ]] || { bad "prereqs"; exit 2; }
ok "prereqs"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/squircle-fill-regr.XXXXXX")"
trap '/usr/bin/trash "$WORK" 2>/dev/null || true' EXIT
FIX="$WORK/plate.png"; OUT="$WORK/out.webp"
"$MAGICK" -size 512x512 xc:'#CC5533' "$FIX"
status="$("$SQUIRCLE_SH" "$FIX" --no-clip-detect --out "$OUT" 2>&1)" || { bad "exit"; echo "$status" >&2; exit 2; }
echo "$status" >&2
echo "$status" | grep -q 'mode: fill' && ok "status fill" || bad "status not fill: $status"
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
(( $? == 0 )) && ok "fill opaque≈mask" || bad "fill opaque≠mask"
echo "squircle-fill-mode.regression pass=$pass fail=$fail" >&2
(( fail == 0 ))
