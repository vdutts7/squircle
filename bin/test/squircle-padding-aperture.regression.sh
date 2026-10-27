#!/usr/bin/env bash
# PARITY: default padding must clear the *squircle aperture*, not merely inset the square canvas.
#
# Bound to: bin/squircle.sh opaque+CLIP_DETECT padding path + bin/mask.png geometry.
# Isolated from: squircle-bg-default (bleed/white-letterbox). This suite owns aperture clearance only.
#
# Core invariant: CLIP_PADDING_START square inset ≈ mask mid-side inset on this mask (~100px at 1024).
# A full-bleed square logo with "padding 100" lands flush on the squircle's flat sides (gap 0) and
# dies on the curve. Desired: ink stays inside the aperture with measurable mid-side + corner clearance.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SQUIRCLE_SH="${SQUIRCLE_SH:-$ROOT/bin/squircle.sh}"
MASK="${MASK:-$ROOT/bin/mask.png}"
MAGICK="${MAGICK:-/opt/homebrew/bin/magick}"
[[ -x "$MAGICK" ]] || MAGICK=/usr/local/bin/magick

# Minimum clearance (px) from squircle opaque edge to non-margin ink. Product lock — not bg color.
MIN_SIDE_GAP="${MIN_SIDE_GAP:-48}"
MIN_CORNER_GAP="${MIN_CORNER_GAP:-48}"
SIZE=1024

pass=0
fail=0
ok() { echo "  ok $1" >&2; pass=$((pass + 1)); }
bad() { echo "  FAIL $1" >&2; fail=$((fail + 1)); }

[[ -x "$SQUIRCLE_SH" ]] || { bad "squircle.sh missing"; exit 2; }
[[ -f "$MASK" ]] || { bad "mask.png missing"; exit 2; }
[[ -x "$MAGICK" ]] || { bad "magick missing"; exit 2; }
ok "binaries present"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/squircle-aperture-regr.XXXXXX")"
cleanup() { /usr/bin/trash "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# Orange ink on WHITE canvas (corners white → low-chroma white margin).
# Fixture class for C-APERTURE: opaque_ink_on_white_margin. Uniform full-bleed orange is
# C-FIELD-PLATE's concern — this suite must keep white margin to measure ink gaps.
FIX="$WORK/fullbleed-plate.png"
"$MAGICK" -size 512x512 xc:white \
  \( -size 400x400 xc:'#F7A41D' \) -gravity center -compose over -composite \
  "$FIX"
ok "fixture fullbleed-plate"

OUT="$WORK/out.webp"
set +e
status="$("$SQUIRCLE_SH" "$FIX" --out "$OUT" 2>&1)"
rc=$?
set -e
echo "$status" >&2
(( rc == 0 )) && ok "squircle exit 0" || bad "squircle exit $rc"
[[ -f "$OUT" ]] && ok "webp written" || bad "webp missing"
echo "$status" | grep -q 'padding' && ok "padding mode engaged" || bad "expected padding mode: $status"

# Measure mask aperture + ink bbox (ink = opaque + not near-white)
python3 - "$OUT" "$MASK" "$SIZE" "$MIN_SIDE_GAP" "$MIN_CORNER_GAP" <<'PY'
import subprocess, sys
out, mask_path, size_s, min_side_s, min_corner_s = sys.argv[1:6]
SIZE = int(size_s)
MIN_SIDE = int(min_side_s)
MIN_CORNER = int(min_corner_s)

rgba = subprocess.check_output(
    ["/opt/homebrew/bin/magick", out, "-depth", "8", "rgba:-"]
)
mask = subprocess.check_output(
    [
        "/opt/homebrew/bin/magick",
        mask_path,
        "-resize",
        f"{SIZE}x{SIZE}",
        "-alpha",
        "extract",
        "-threshold",
        "50%",
        "-depth",
        "8",
        "gray:-",
    ]
)

def px(x, y):
    i = (y * SIZE + x) * 4
    return rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]

def mv(x, y):
    return mask[y * SIZE + x]

def is_ink(r, g, b, a):
    if a < 200:
        return False
    # near-white margin / plate letterbox — not ink
    if r >= 245 and g >= 245 and b >= 245:
        return False
    return True

ink = []
for y in range(SIZE):
    for x in range(SIZE):
        r, g, b, a = px(x, y)
        if is_ink(r, g, b, a):
            ink.append((x, y))

if not ink:
    print("FAIL no ink pixels found", file=sys.stderr)
    sys.exit(2)

xs = [p[0] for p in ink]
ys = [p[1] for p in ink]
left, right, top, bot = min(xs), max(xs), min(ys), max(ys)
print(f"ink_bbox={left},{top},{right},{bot}", file=sys.stderr)

def first_opaque_y(x):
    for y in range(SIZE):
        if mv(x, y) > 127:
            return y
    return None

def last_opaque_y(x):
    for y in range(SIZE - 1, -1, -1):
        if mv(x, y) > 127:
            return y
    return None

def first_opaque_x(y):
    for x in range(SIZE):
        if mv(x, y) > 127:
            return x
    return None

def last_opaque_x(y):
    for x in range(SIZE - 1, -1, -1):
        if mv(x, y) > 127:
            return x
    return None

mid = SIZE // 2
mt, mb = first_opaque_y(mid), last_opaque_y(mid)
ml, mr = first_opaque_x(mid), last_opaque_x(mid)
gap_top = top - mt
gap_bot = mb - bot
gap_left = left - ml
gap_right = mr - right
print(
    f"mid_gaps top={gap_top} bot={gap_bot} left={gap_left} right={gap_right} "
    f"mask=({ml},{mt})-({mr},{mb})",
    file=sys.stderr,
)

rc = 0
for name, gap in (
    ("top", gap_top),
    ("bot", gap_bot),
    ("left", gap_left),
    ("right", gap_right),
):
    if gap < MIN_SIDE:
        print(f"FAIL mid-side {name} gap {gap} < {MIN_SIDE}", file=sys.stderr)
        rc = 2
    else:
        print(f"ok mid-side {name} gap {gap}", file=sys.stderr)

# Corner clearance: nearest ink to NW/NE/SW/SE mask frontier along 45° band
def corner_gap(x0, y0, dx, dy):
    """Walk from outside toward center; find first mask-opaque then first ink; return ink-mask gap."""
    # find first opaque on ray
    x, y = x0, y0
    mask_hit = None
    for _ in range(SIZE):
        if 0 <= x < SIZE and 0 <= y < SIZE and mv(x, y) > 127:
            mask_hit = (x, y)
            break
        x += dx
        y += dy
    if mask_hit is None:
        return None
    x, y = mask_hit
    for _ in range(SIZE):
        if not (0 <= x < SIZE and 0 <= y < SIZE):
            return None
        r, g, b, a = px(x, y)
        if is_ink(r, g, b, a):
            # chebyshev-ish steps from mask_hit
            return max(abs(x - mask_hit[0]), abs(y - mask_hit[1]))
        x += dx
        y += dy
    return SIZE  # no ink on ray → huge clearance

for label, args in (
    ("NW", (0, 0, 1, 1)),
    ("NE", (SIZE - 1, 0, -1, 1)),
    ("SW", (0, SIZE - 1, 1, -1)),
    ("SE", (SIZE - 1, SIZE - 1, -1, -1)),
):
    g = corner_gap(*args)
    if g is None:
        print(f"FAIL corner {label} gap unmeasurable", file=sys.stderr)
        rc = 2
    elif g < MIN_CORNER:
        print(f"FAIL corner {label} gap {g} < {MIN_CORNER}", file=sys.stderr)
        rc = 2
    else:
        print(f"ok corner {label} gap {g}", file=sys.stderr)

sys.exit(rc)
PY
py_rc=$?
if (( py_rc == 0 )); then
  ok "aperture clearance (side>=${MIN_SIDE_GAP} corner>=${MIN_CORNER_GAP})"
else
  bad "aperture clearance below floor"
fi

echo "squircle-padding-aperture.regression pass=$pass fail=$fail" >&2
(( fail == 0 )) && exit 0
exit 2
