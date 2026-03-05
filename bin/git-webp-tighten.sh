#!/bin/zsh
# git-webp-tighten.sh - Git history rewrite: webp/ has only "latest" or "last N" versions; full history for everything else.
# Usage: ./git-webp-tighten.sh [N]
#   N from config (bin/git-webp-tighten.config WINDOW=) when no arg; else N=1.
#   N=1: In every commit, replace webp/ with HEAD's webp/. One copy of webp in object store.
#   N>1: Sliding window of last N commits keep their webp/; older commits get Nth-from-tip's webp/.
# Runs git gc --aggressive --prune=now at the end.

set -e
ROOT="$(git rev-parse --show-toplevel)"
SCRIPT_DIR="${0:h}"
cd "$ROOT"

# Default N: from config file (next to script), else 1
if [[ -n "$1" ]]; then
  N="$1"
else
  N=1
  if [[ -f "$SCRIPT_DIR/git-webp-tighten.config" ]]; then
    source "$SCRIPT_DIR/git-webp-tighten.config" 2>/dev/null || true
    [[ -n "$WINDOW" ]] && N="$WINDOW"
  fi
fi

if [[ "$N" -lt 1 ]]; then
  echo "Usage: ${0:t} [N]  (N=1 for latest only, N>1 for sliding window of last N)" >&2
  exit 1
fi

# Ref that will be rewritten (we rewrite all refs, but need HEAD for the "source" webp content)
if ! git rev-parse HEAD &>/dev/null; then
  echo "No HEAD (empty repo?)." >&2
  exit 1
fi

if [[ $N -eq 1 ]]; then
  # Every commit: webp/ = HEAD's webp/
  echo "Rewriting history: webp/ = HEAD in every commit (latest only)..."
  git filter-branch -f --tree-filter 'rm -rf webp 2>/dev/null; git checkout HEAD -- webp/ 2>/dev/null || true' -- --all
else
  # Sliding window: last N commits keep their webp/; older commits get webp/ from the Nth-from-tip commit
  LAST_N=("${(f)"$(git rev-list -n "$N" HEAD)"}")
  if [[ ${#LAST_N[@]} -lt $N ]]; then
    echo "Fewer than $N commits; using latest-only logic."
    git filter-branch -f --tree-filter 'rm -rf webp 2>/dev/null; git checkout HEAD -- webp/ 2>/dev/null || true' -- --all
  else
    # Nth commit from tip (0-indexed: LAST_N[N] is the oldest in the window)
    COMMIT_N="${LAST_N[$N]}"
    export COMMIT_N
    export N
    export LAST_N_LIST="${(j: :)LAST_N}"
    echo "Rewriting history: last $N commits keep their webp/; older commits get webp/ from ${COMMIT_N:0:8}..."
    git filter-branch -f --tree-filter '
      if (echo "$LAST_N_LIST" | tr " " "\n" | grep -q "^${GIT_COMMIT}$"); then
        true
      else
        rm -rf webp 2>/dev/null
        git checkout "$COMMIT_N" -- webp/ 2>/dev/null || true
      fi
    ' -- --all
  fi
fi

git gc --aggressive --prune=now
echo "Done."
