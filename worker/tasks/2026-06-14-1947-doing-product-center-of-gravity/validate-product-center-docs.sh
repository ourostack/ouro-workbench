#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

docs=(
  README.md
  docs/guide.md
  docs/roadmap.md
  docs/workbench-surface-spec.md
)

patterns=(
  'local terminal wrapper'
  'local shell wrapper'
  'persistent `Local Shell`'
  'default `Local Shell`'
  'Local Shell` session'
  'Keep a persistent `Local Shell`'
)

failed=false
for pattern in "${patterns[@]}"; do
  if rg -n --fixed-strings "$pattern" "${docs[@]}"; then
    failed=true
  fi
done

if [[ "$failed" == "true" ]]; then
  echo "Product-center doc validation failed: current docs still recommend default Local Shell or wrapper framing." >&2
  exit 1
fi

echo "Product-center doc validation passed."
