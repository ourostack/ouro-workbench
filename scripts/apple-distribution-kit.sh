#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -n "${APPLE_DISTRIBUTION_KIT_BIN:-}" ]]; then
  exec "$APPLE_DISTRIBUTION_KIT_BIN" "$@"
fi

if [[ -f "$ROOT_DIR/.ci/apple-distribution-kit/dist/cli.js" ]]; then
  exec node "$ROOT_DIR/.ci/apple-distribution-kit/dist/cli.js" "$@"
fi

if [[ -f "$ROOT_DIR/../apple-distribution-kit/dist/cli.js" ]]; then
  exec node "$ROOT_DIR/../apple-distribution-kit/dist/cli.js" "$@"
fi

if command -v apple-distribution-kit >/dev/null 2>&1; then
  exec apple-distribution-kit "$@"
fi

cat >&2 <<'EOF'
apple-distribution-kit is unavailable.

Build the sibling shared kit repo:
  cd ../apple-distribution-kit
  npm ci
  npm run build

Or set APPLE_DISTRIBUTION_KIT_BIN to an executable apple-distribution-kit CLI.
EOF
exit 127
