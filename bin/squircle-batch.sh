#!/usr/bin/env bash
# Run squircle on every file in a directory in parallel (GNU Parallel).
# Usage: squircle-batch.sh <directory>
# -j 0 = one job per CPU core; avoids overloading. Export WEBP to send output to webp/.

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SQUIRCLE="${SCRIPT_DIR}/squircle.sh"
[[ -x "$SQUIRCLE" ]] || { echo "squircle not found at $SQUIRCLE"; exit 1; }

command -v parallel &>/dev/null || { echo "GNU Parallel required: brew install parallel"; exit 1; }

DIR="${1:?Usage: $0 <directory>}"
[[ -d "$DIR" ]] || { echo "Not a directory: $DIR"; exit 1; }

# One file per line; only regular files. -j 0 = one job per CPU core (max efficiency, no overkill).
for f in "$DIR"/*; do
  [[ -f "$f" ]] && echo "$f"
done | parallel -j 0 "$SQUIRCLE" {}

echo "Done."
