#!/usr/bin/env zsh
# Repo .venv: create if missing, upgrade pip, install requirements (default requirements.txt).
# Usage: ./bin/venv.zsh [requirements-file]     paths relative to repo root or absolute
set -e
setopt pipefail 2>/dev/null || true
SCRIPT_DIR="${0:A:h}"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
PY="${PYTHON:-python3}"
REQ_NAME="${1:-requirements.txt}"
if [[ "$REQ_NAME" == /* ]]; then
  REQ="$REQ_NAME"
else
  REQ="$REPO_ROOT/$REQ_NAME"
fi
[[ -f "$REQ" ]] || { echo "🔴 missing requirements file: $REQ" >&2; exit 1 }

VENV="$REPO_ROOT/.venv"
if [[ ! -x "$VENV/bin/python3" ]]; then
  "$PY" -m venv "$VENV"
fi
"$VENV/bin/pip" install -U pip -q
"$VENV/bin/pip" install -q -r "$REQ"
print -r -- "🟢 $VENV ← $(basename "$REQ")"
