#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Ouro Workbench.app"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ouro-workbench-install-rollback.XXXXXX")"
INSTALL_DIR="$TEMP_ROOT/Applications"
COUNT_FILE="$TEMP_ROOT/verify-count"
MARKER_PATH="Contents/Resources/rollback-marker"
VERIFIER="$TEMP_ROOT/verify-app-bundle-once.sh"

cleanup() {
  rm -rf "$TEMP_ROOT"
}

trap cleanup EXIT

cd "$ROOT_DIR"

scripts/package-app.sh >/dev/null
mkdir -p "$INSTALL_DIR"
ditto "dist/$APP_NAME" "$INSTALL_DIR/$APP_NAME"
mkdir -p "$INSTALL_DIR/$APP_NAME/Contents/Resources"
printf 'previous app survived rollback\n' > "$INSTALL_DIR/$APP_NAME/$MARKER_PATH"
codesign --force --deep --sign - "$INSTALL_DIR/$APP_NAME" >/dev/null

{
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  printf 'count_file=%q\n' "$COUNT_FILE"
  printf 'real_verifier=%q\n' "$ROOT_DIR/scripts/verify-app-bundle.sh"
  printf 'count=0\n'
  printf 'if [[ -f "$count_file" ]]; then count="$(cat "$count_file")"; fi\n'
  printf 'count=$((count + 1))\n'
  printf 'printf "%%s\\n" "$count" > "$count_file"\n'
  printf 'if [[ "$count" -eq 1 ]]; then exec "$real_verifier" "$@"; fi\n'
  printf 'printf "simulated installed-bundle verification failure\\n" >&2\n'
  printf 'exit 42\n'
} > "$VERIFIER"
chmod 755 "$VERIFIER"

set +e
scripts/install-app.sh --install-dir "$INSTALL_DIR" --verify-script "$VERIFIER" >/dev/null 2>"$TEMP_ROOT/install.err"
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  printf 'Install rollback smoke failed: simulated verifier unexpectedly passed\n' >&2
  exit 1
fi

if [[ ! -f "$INSTALL_DIR/$APP_NAME/$MARKER_PATH" ]]; then
  printf 'Install rollback smoke failed: previous app marker was not restored\n' >&2
  exit 1
fi

if [[ "$(cat "$COUNT_FILE")" != "2" ]]; then
  printf 'Install rollback smoke failed: expected verifier to run twice\n' >&2
  exit 1
fi

scripts/verify-app-bundle.sh "$INSTALL_DIR/$APP_NAME" >/dev/null
printf 'Install rollback smoke passed\n'
