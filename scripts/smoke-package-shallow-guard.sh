#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEMP_ROOT"' EXIT

SOURCE_REPO="$TEMP_ROOT/source"
SHALLOW_REPO="$TEMP_ROOT/shallow"
mkdir -p "$SOURCE_REPO/scripts"

cp "$ROOT_DIR/scripts/package-app.sh" "$SOURCE_REPO/scripts/package-app.sh"
cp "$ROOT_DIR/VERSION" "$SOURCE_REPO/VERSION"

git -C "$SOURCE_REPO" init --quiet
git -C "$SOURCE_REPO" add VERSION scripts/package-app.sh
git -C "$SOURCE_REPO" \
  -c user.name="Ouro Workbench CI" \
  -c user.email="workbench@example.invalid" \
  commit --quiet -m "seed shallow package guard smoke"

git clone --quiet --depth 1 "file://$SOURCE_REPO" "$SHALLOW_REPO"

set +e
"$SHALLOW_REPO/scripts/package-app.sh" >"$TEMP_ROOT/stdout.log" 2>"$TEMP_ROOT/stderr.log"
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  printf 'Expected package-app.sh to reject a shallow checkout, but it succeeded.\n' >&2
  exit 1
fi

if ! grep -q 'shallow git checkout' "$TEMP_ROOT/stderr.log"; then
  printf 'Expected shallow checkout error, got:\n' >&2
  cat "$TEMP_ROOT/stderr.log" >&2
  exit 1
fi

printf 'package-app shallow checkout guard ok\n'
