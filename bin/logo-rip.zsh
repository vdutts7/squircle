#!/bin/zsh
# Deprecated entrypoint: use ./bin/squircle.sh --domain <host> [--logo-rip-only] [--logo-rip-keep] [--out ...]
set -e
setopt pipefail 2>/dev/null || true
SCRIPT_DIR="${0:h}"
[[ -n "${1:-}" ]] || { echo "usage: $0 <domain> [--keep] [--squircle] [--out path.webp]" >&2; exit 1 }
typeset -a fwd=(--domain "$1")
shift
while [[ -n "${1:-}" ]]; do
  case "$1" in
    --keep) fwd+=(--logo-rip-keep); shift ;;
    --squircle) shift ;;
    --out=*)
      fwd+=("$1")
      shift
      ;;
    --out)
      shift
      [[ -n "${1:-}" ]] || { echo "error: --out needs a path" >&2; exit 1 }
      fwd+=(--out "$1")
      shift
      ;;
    *)
      echo "error: unknown flag: $1" >&2
      echo "usage: $0 <domain> [--keep] [--squircle] [--out path.webp]" >&2
      exit 1
      ;;
  esac
done
exec "$SCRIPT_DIR/squircle.sh" "${fwd[@]}"
