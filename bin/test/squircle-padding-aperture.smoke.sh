#!/usr/bin/env bash
# Smoke → aperture clearance regression (isolated from bg-default).
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/squircle-padding-aperture.regression.sh" "$@"
