#!/usr/bin/env bash
exec "${CURTOOLS:-$HOME/.cursor/tools}/git/githooks/scripts/block-artifact-paths.sh" "$@"
