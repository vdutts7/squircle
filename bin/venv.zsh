#!/usr/bin/env zsh
# Tools-directory .venv: created next to squircle.sh / phash-pick.zsh (e.g. $CURTOOLS/.venv).
# requirements: default $TOOLS/requirements.txt, else parent ../requirements.txt (legacy repo layout).
# Usage: ./venv.zsh [requirements-file-or-name]   absolute path OK; relative names resolve under TOOLS then repo parent
set -e
setopt pipefail 2>/dev/null || true
TOOLS="${0:A:h}"
cd "$TOOLS"
PY="${PYTHON:-python3}"

resolve_req() {
  local name="$1"
  if [[ "$name" == /* ]]; then
    [[ -f "$name" ]] && { print -r -- "$name"; return 0 }
    return 1
  fi
  [[ -f "$TOOLS/$name" ]] && { print -r -- "$TOOLS/$name"; return 0 }
  local up
  up="$(cd "$TOOLS/.." && pwd)"
  [[ -f "$up/$name" ]] && { print -r -- "$up/$name"; return 0 }
  return 1
}

typeset REQ
if (( $# )); then
  REQ="$(resolve_req "$1")" || { echo "🔴 missing requirements file: $1" >&2; exit 1 }
elif [[ -f "$TOOLS/requirements.txt" ]]; then
  REQ="$TOOLS/requirements.txt"
else
  up="$(cd "$TOOLS/.." && pwd)"
  if [[ -f "$up/requirements.txt" ]]; then
    REQ="$up/requirements.txt"
  else
    echo "🔴 missing requirements.txt (expected $TOOLS/requirements.txt)" >&2
    exit 1
  fi
fi

VENV="$TOOLS/.venv"
if [[ ! -x "$VENV/bin/python3" ]]; then
  "$PY" -m venv "$VENV"
fi
"$VENV/bin/pip" install -U pip -q
"$VENV/bin/pip" install -q -r "$REQ"
print -r -- "🟢 $VENV ← $(basename "$REQ")"
