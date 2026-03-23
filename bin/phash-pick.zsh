#!/usr/bin/env zsh
# pHash pick: anchor vs candidates → stdout = best path (largest max dimension within Hamming threshold).
# Python: SCRIPT_DIR/.venv/bin/python3 (tools dir, e.g. $CURTOOLS), else legacy ../.venv, else PYTHON or python3.
# Usage: ./bin/phash-pick.zsh [--threshold N] [--max-edge M] ANCHOR CAND1 [CAND2 ...]
#   --max-edge M: prefer candidates with max(w,h) <= M; if none qualify, fall back to any Hamming match (largest).
SCRIPT_DIR="${0:A:h}"
if [[ -n "${PYTHON:-}" ]]; then
  :
elif [[ -x "$SCRIPT_DIR/.venv/bin/python3" ]]; then
  PYTHON="$SCRIPT_DIR/.venv/bin/python3"
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  if [[ -x "$REPO_ROOT/.venv/bin/python3" ]]; then
    PYTHON="$REPO_ROOT/.venv/bin/python3"
  else
    PYTHON=python3
  fi
fi
exec "$PYTHON" - "$@" <<'PY'
import sys
from pathlib import Path

def die(m, c=1):
    print(m, file=sys.stderr)
    sys.exit(c)

try:
    import imagehash
    from PIL import Image
except ImportError:
    die("need: ./venv.zsh in the same dir (installs into .venv next to these scripts)", 1)

argv = sys.argv[1:]
th = 10
max_edge_cap = None
while len(argv) >= 2:
    if argv[0] == "--threshold":
        th = int(argv[1])
        argv = argv[2:]
        continue
    if argv[0] == "--max-edge":
        max_edge_cap = int(argv[1])
        argv = argv[2:]
        continue
    break
if len(argv) < 2:
    die("usage: phash-pick.zsh [--threshold N] [--max-edge M] ANCHOR CAND1 [CAND2 ...]", 2)

anchor_p = Path(argv[0])
cands = [Path(p) for p in argv[1:]]
for p in [anchor_p] + cands:
    if not p.is_file():
        die(f"not a file: {p}", 1)

def phash_path(p):
    return imagehash.phash(Image.open(p))

def max_edge(p):
    im = Image.open(p)
    w, h = im.size
    return max(w, h)

try:
    ha = phash_path(anchor_p)
except Exception as e:
    die(f"anchor phash failed: {e}", 1)

def pick_best(cands_filt):
    best = None
    best_m = -1
    for p in cands_filt:
        try:
            d = ha - phash_path(p)
        except Exception:
            continue
        if d > th:
            continue
        m = max_edge(p)
        if m > best_m:
            best_m = m
            best = p
    return best

# First pass: Hamming + optional max-edge cap (avoids 4k junk that barely matches tiny favicon).
if max_edge_cap is not None:
    capped = [p for p in cands if max_edge(p) <= max_edge_cap]
    best = pick_best(capped)
else:
    best = None
if best is None:
    best = pick_best(cands)

out = best if best is not None else anchor_p
print(out.resolve())
PY
