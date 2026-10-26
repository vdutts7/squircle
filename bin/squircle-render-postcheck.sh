#!/usr/bin/env bash
# Post-render constraints ($CURREGISTRY/squircle/render-csp/constraints.json)
# Usage: squircle-render-postcheck.sh <source> <plan.json> <output.webp>
set -euo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
MAGICK=/opt/homebrew/bin/magick
[[ -x "$MAGICK" ]] || MAGICK=/usr/local/bin/magick

SRC="${1:?source}"; PLAN="${2:?plan}"; OUT="${3:?out}"
[[ -f "$SRC" && -f "$PLAN" && -f "$OUT" ]] || { echo "postcheck: missing input" >&2; exit 2; }

fail() { echo "postcheck FAIL [$1] $2" >&2; exit 1; }

MARGIN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["margin_hex"])' "$PLAN")
MODE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("render_mode","padding"))' "$PLAN")
P=$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1])).get("padding_px",0)))' "$PLAN")
CS=$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get("clip_score"); print(v if v is not None else "")' "$PLAN")

FIELD=$("$BIN/detect-field-color.sh" -q "$SRC")

if [[ "$MODE" == "padding" ]]; then
  if ! python3 - "$MARGIN" "$FIELD" <<'PY'
import sys
def parse(h):
    h=h.strip().lstrip("#")
    return tuple(int(h[i:i+2],16) for i in (0,2,4))
def close(a,b,tol=2):
    return all(abs(x-y)<=tol for x,y in zip(a,b))
m,f = map(parse, sys.argv[1:3])
if not close(m,f):
    sys.exit(1)
PY
  then
    fail "margin_matches_field_color" "margin $MARGIN field $FIELD"
  fi
fi

AOUT=$($MAGICK "$OUT" -alpha extract -crop 48x48+0+0 +repage -format '%[fx:mean]' info:)
awk -v a="$AOUT" 'BEGIN{ if(a+0 >= 0.05) exit 1 }' || fail "outside_mask_transparent" "corner alpha mean=$AOUT"

if [[ "$MODE" == "padding" && -n "$CS" ]]; then
  awk -v s="$CS" 'BEGIN{ if(s+0 >= 0.05) exit 1 }' || fail "plan_clip_score" "clip_score=$CS"
fi

TRIM=$($MAGICK "$SRC" -fuzz 4% -trim +repage -format '%w %h' info: 2>/dev/null || echo "0 0")
read -r TW TH <<<"$TRIM"
if [[ "$TW" -gt 0 && "$TH" -gt 0 ]]; then
  ASPECT=$(python3 -c 'import sys; w,h=map(int,sys.argv[1:3]); print(max(w,h)/max(min(w,h),1))' "$TW" "$TH")
  awk -v a="$ASPECT" -v p="$P" 'BEGIN{ if(a>3 && p<120) exit 1 }' || fail "wide_wordmark_padding" "aspect=$ASPECT padding=$P"
fi
