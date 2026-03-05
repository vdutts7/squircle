#!/usr/bin/env bash
# Run squircle on every file in a directory.
# Usage: squircle-dir.sh <directory>

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SQUIRCLE="${SCRIPT_DIR}/squircle.sh"
[[ -x "$SQUIRCLE" ]] || { echo "squircle not found at $SQUIRCLE"; exit 1; }

DIR="${1:?Usage: $0 <directory>}"
[[ -d "$DIR" ]] || { echo "Not a directory: $DIR"; exit 1; }

for f in "$DIR"/*; do
  [[ -e "$f" ]] || continue
  [[ -f "$f" ]] || continue
  echo "Running squircle on: $f"
  "$SQUIRCLE" "$f"
done
echo "Done."
