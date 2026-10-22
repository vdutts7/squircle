#!/usr/bin/env zsh
# Sweep webp/ litter: .CLIPPED, clip-queue sidecars, spaced paths, incumbent dupes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

trash_path() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  if command -v trash >/dev/null 2>&1; then
    trash -- "$f"
  else
    rm -f -- "$f"
  fi
}

typeset -A seen
while IFS= read -r f; do
  [[ -n "$f" ]] && seen[$f]=1
done < <(find webp -type f \( -name '*.CLIPPED' -o -name 'clip-queue-unfixed.txt' -o -name '.clip_queue_unfixed.txt' -o -name '* *' \) 2>/dev/null)

while IFS= read -r f; do
  [[ -n "$f" ]] && seen[$f]=1
done < <(
  git ls-files 'webp/' | python3 -c '
import re, sys
rx = re.compile(r"-[0-9]{8}-[0-9]{6}\.webp$")
for rel in map(str.strip, sys.stdin):
    if not rel:
        continue
    if rx.search(rel) or rel.endswith(".CLIPPED") or " " in rel:
        print(rel)
    if rel.endswith("clip-queue-unfixed.txt") or rel.endswith(".clip_queue_unfixed.txt"):
        print(rel)
'
)

n=0
for f in ${(k)seen}; do
  if git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
    git rm -f -- "$f"
  else
    trash_path "$f"
  fi
  n=$((n + 1))
done

echo "post-cleanup-webp-litter: cleared $n path(s)"
