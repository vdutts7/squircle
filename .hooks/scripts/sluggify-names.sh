#!/usr/bin/env zsh
# Slug staged or tracked file basenames via $PATH sluggify (sanitize-profile + sluggify-core).
# usage: sluggify-names.sh [--staged|--tree]
set -euo pipefail

MODE="staged"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --staged) MODE="staged"; shift ;;
    --tree) MODE="tree"; shift ;;
    -h|--help)
      echo "usage: $0 [--staged|--tree]" >&2
      exit 0
      ;;
    *) echo "sluggify-names: unknown arg: $1" >&2; exit 2 ;;
  esac
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

SLUGGIFY="${SLUGGIFY:-$(command -v sluggify 2>/dev/null || true)}"
if [[ -z "$SLUGGIFY" || ! -x "$SLUGGIFY" ]]; then
  echo "[sluggify-names] sluggify not in PATH; skip" >&2
  exit 0
fi

should_skip() {
  local rel="$1"
  case "$rel" in
    .git/*|.git|.hooks/*|.hooks) return 0 ;;
    bin/.venv/*|bin/.venv) return 0 ;;
    bin/mask.png) return 0 ;;
    image-formats.txt|repo.spine.json|em-dash-whitelist.txt) return 0 ;;
  esac
  return 1
}

typeset -a paths=()
if [[ "$MODE" == "tree" ]]; then
  while IFS= read -r -d '' rel; do
    [[ -n "$rel" ]] && paths+=("$rel")
  done < <(git ls-files -z)
else
  while IFS= read -r -d '' rel; do
    [[ -n "$rel" ]] && paths+=("$rel")
  done < <(git diff --cached --name-only -z --diff-filter=ACMR)
fi

(( ${#paths[@]} == 0 )) && exit 0

typeset -a touched_dirs=()
renamed=0

for rel in "${paths[@]}"; do
  should_skip "$rel" && continue
  [[ -f "$rel" ]] || continue

  if ! "$SLUGGIFY" --dry-run -q "$rel" 2>/dev/null | grep -q .; then
    continue
  fi

  if ! "$SLUGGIFY" -q "$rel"; then
    echo "[sluggify-names] failed: $rel" >&2
    exit 1
  fi
  renamed=$((renamed + 1))
  touched_dirs+=("$(dirname "$rel")")
done

(( renamed == 0 )) && exit 0

typeset -A seen_dirs=()
for d in "${touched_dirs[@]}"; do
  [[ -n "${seen_dirs[$d]:-}" ]] && continue
  seen_dirs[$d]=1
  git add -u -- "$d" 2>/dev/null || true
  git add -- "$d" 2>/dev/null || true
done

echo "[sluggify-names] renamed=${renamed} mode=${MODE}" >&2
exit 0
