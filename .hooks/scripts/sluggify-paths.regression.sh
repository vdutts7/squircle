#!/usr/bin/env bash
# PARITY: squircle vendored sluggify-paths (--staged|--tree) + pre-commit/pre-push wire.
set -euo pipefail

HOOK_SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT_SRC="$(cd "$HOOK_SRC/../.." && pwd)"
TARGET="$HOOK_SRC/sluggify-paths.sh"

pass=0
fail=0
ok() { echo "  ok $1" >&2; pass=$((pass + 1)); }
bad() { echo "  FAIL $1" >&2; fail=$((fail + 1)); }

[[ -x "$TARGET" ]] || { bad "target not executable"; exit 2; }
ok "target executable"

set +e
"$TARGET" --help >/dev/null 2>&1
hc=$?
set -e
[[ "$hc" -eq 0 ]] && ok "--help exit 0" || bad "--help exit $hc"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/squircle-slug-regr.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$WORK/.hooks/scripts"
cp "$HOOK_SRC/sluggify-paths.sh" "$HOOK_SRC/sluggify-paths.excludes.json" "$WORK/.hooks/scripts/"
chmod +x "$WORK/.hooks/scripts/sluggify-paths.sh"
cp "$ROOT_SRC/image-formats.txt" "$WORK/" 2>/dev/null || echo 'webp	webp' > "$WORK/image-formats.txt"
cp "$ROOT_SRC/.hooks/pre-commit" "$ROOT_SRC/.hooks/pre-push" "$WORK/.hooks/"
chmod +x "$WORK/.hooks/pre-commit" "$WORK/.hooks/pre-push"
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/check-repo-size.sh"
chmod +x "$WORK/bin/check-repo-size.sh"

cd "$WORK"
git init -q
git config user.email regr@test
git config user.name regr
git add image-formats.txt
git commit -q -m init

# --staged
mkdir -p webp bin
printf x > 'webp/My Bad File.webp'
printf y > 'bin/keep Me.sh'
git add 'webp/My Bad File.webp'
"$WORK/.hooks/scripts/sluggify-paths.sh" --staged "$WORK"
[[ -f webp/my-bad-file.webp ]] && ok "--staged rename" || bad "--staged rename"
[[ -f 'bin/keep Me.sh' ]] && ok "excludes bin/" || bad "excludes bin/"

git commit -q -m staged

# --tree (explicit)
printf a > 'webp/Another ONE.webp'
git add 'webp/Another ONE.webp'
git commit -q -m prep-tree
"$WORK/.hooks/scripts/sluggify-paths.sh" --tree "$WORK"
[[ -f webp/another-one.webp ]] && ok "--tree rename" || bad "--tree rename"

# default mode = tree
printf b > 'webp/Third FILE.webp'
git add 'webp/Third FILE.webp'
git commit -q -m prep-default
"$WORK/.hooks/scripts/sluggify-paths.sh" "$WORK"
[[ -f webp/third-file.webp ]] && ok "default tree" || bad "default tree"

# already slugged → no crash
"$WORK/.hooks/scripts/sluggify-paths.sh" --tree "$WORK"
[[ -f webp/third-file.webp ]] && ok "idempotent tree" || bad "idempotent tree"

# pre-commit wire
mkdir -p notes
printf hi > 'notes/My Note.txt'
git add 'notes/My Note.txt'
"$WORK/.hooks/pre-commit" >/dev/null
[[ -f notes/my-note.txt ]] && ok "pre-commit" || bad "pre-commit"

# pre-push wire
printf z > 'webp/Needs Slug.webp'
git add 'webp/Needs Slug.webp'
git commit -q -m badname
set +e
"$WORK/.hooks/pre-push" >/dev/null 2>&1
pp_rc=$?
set -e
[[ -f webp/needs-slug.webp ]] && ok "pre-push slug" || bad "pre-push slug"
[[ "$pp_rc" -eq 1 ]] && ok "pre-push exit 1 retry" || bad "pre-push exit $pp_rc"

echo "sluggify-paths.regression pass=$pass fail=$fail" >&2
(( fail == 0 )) && exit 0
exit 2
