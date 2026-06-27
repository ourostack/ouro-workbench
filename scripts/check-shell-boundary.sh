#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

checker=".build/checkouts/ouro-native-apple-app-shell/scripts/check-shell-boundary.sh"
if [[ ! -x "$checker" ]]; then
  swift package resolve >/dev/null
fi

[[ -x "$checker" ]] || {
  printf 'error: missing shell boundary checker at %s\n' "$checker" >&2
  exit 1
}

if [[ "${1:-}" == "--selftest" ]]; then
  exec "$checker" --selftest
fi

exec "$checker" --repo "$ROOT_DIR" --allowlist "$ROOT_DIR/scripts/shell-boundary-allowlist.txt"
