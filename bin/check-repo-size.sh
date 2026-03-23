#!/usr/bin/env zsh
# Warn when git packed object size exceeds a configurable threshold.
# Threshold source (first match wins):
#   1) CLI arg in MiB
#   2) SIZE_PACK_WARN_MB env var
#   3) bin/repo-size-watch.config SIZE_PACK_WARN_MB=
#   4) default 500 MiB

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${ROOT}" ]]; then
  echo "not a git repository" >&2
  exit 2
fi

SCRIPT_DIR="${0:A:h}"
CONFIG_FILE="${SCRIPT_DIR}/repo-size-watch.config"

THRESHOLD_MB="${1:-${SIZE_PACK_WARN_MB:-}}"
if [[ -z "${THRESHOLD_MB}" && -f "${CONFIG_FILE}" ]]; then
  source "${CONFIG_FILE}" 2>/dev/null || true
  THRESHOLD_MB="${SIZE_PACK_WARN_MB:-}"
fi
THRESHOLD_MB="${THRESHOLD_MB:-500}"

if ! [[ "${THRESHOLD_MB}" =~ '^[0-9]+$' ]]; then
  echo "invalid threshold '${THRESHOLD_MB}' (expected integer MiB)" >&2
  exit 2
fi

SIZE_PACK_KB="$(git count-objects -v | awk '$1=="size-pack" {print $2}')"
SIZE_PACK_KB="${SIZE_PACK_KB:-0}"

if ! [[ "${SIZE_PACK_KB}" =~ '^[0-9]+$' ]]; then
  echo "unable to parse size-pack from git count-objects -v" >&2
  exit 2
fi

SIZE_PACK_MB="$(( (SIZE_PACK_KB + 1023) / 1024 ))"

if (( SIZE_PACK_MB > THRESHOLD_MB )); then
  echo "[repo-size] WARNING: size-pack=${SIZE_PACK_MB}MiB exceeds threshold=${THRESHOLD_MB}MiB"
  echo "[repo-size] Suggested cleanup: ./bin/git-webp-tighten.sh"
  echo "[repo-size] Override threshold: SIZE_PACK_WARN_MB=<MiB> ./bin/check-repo-size.sh"
  exit 1
fi

echo "[repo-size] OK: size-pack=${SIZE_PACK_MB}MiB threshold=${THRESHOLD_MB}MiB"
exit 0
