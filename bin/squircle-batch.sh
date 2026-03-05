#!/usr/bin/env bash
# Run squircle on every file in a directory in parallel (GNU Parallel).
# Usage: squircle-batch.sh <directory>
# Output always goes to repo webp/ (SQUIRCLE = repo root). Override with env SQUIRCLE.

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export SQUIRCLE="${SQUIRCLE:-$ROOT}"

SQUIRCLE_SCRIPT="${SCRIPT_DIR}/squircle.sh"
[[ -x "$SQUIRCLE_SCRIPT" ]] || { echo "squircle not found at $SQUIRCLE_SCRIPT"; exit 1; }

command -v parallel &>/dev/null || { echo "GNU Parallel required: brew install parallel"; exit 1; }

DIR="${1:?Usage: $0 <directory>}"
[[ -d "$DIR" ]] || { echo "Not a directory: $DIR"; exit 1; }

# One file per line; only regular files. -j 0 = one job per CPU. --no-notice = no citation prose.
for f in "$DIR"/*; do
  [[ -f "$f" ]] && echo "$f"
done | parallel --no-notice -j 0 "$SQUIRCLE_SCRIPT" {}

echo "Done."
