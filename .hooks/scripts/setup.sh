#!/usr/bin/env zsh
# One-time setup after clone: activate pre-commit hook (validates 1024×1024 WebP under webp/).
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
git config --local include.path ../.gitconfig
chmod +x .hooks/* .hooks/scripts/*.sh 2>/dev/null || true
echo "hooks activated: .hooks/pre-commit"
