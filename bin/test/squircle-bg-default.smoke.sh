#!/usr/bin/env bash
# Smoke → full regression (single runner).
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/squircle-bg-default.regression.sh" "$@"
