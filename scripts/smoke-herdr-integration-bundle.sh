#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$("$ROOT_DIR/scripts/read-workbench-release.sh")"
APP_DIR="${1:-$ROOT_DIR/dist/$WORKBENCH_APP_NAME.app}"
INTEGRATION_DIR="$APP_DIR/Contents/Resources/integrations/herdr"
TEMP_ROOT="$(mktemp -d)"
RUNTIME_ROOT="$TEMP_ROOT/runtime"
trap 'rm -rf "$TEMP_ROOT"' EXIT
chmod 700 "$TEMP_ROOT"

"$INTEGRATION_DIR/static/install.sh" "$APP_DIR" "$RUNTIME_ROOT" >/dev/null
REVISION="$(/usr/bin/plutil -extract revision raw -o - "$INTEGRATION_DIR/runtime/manifest.json")"
INSTALLED_HELPER="$RUNTIME_ROOT/versions/$REVISION/bin/OuroWorkbenchRemote"
[[ -x "$INSTALLED_HELPER" ]] || { printf 'Herdr integration smoke failed: helper was not installed\n' >&2; exit 1; }
[[ "$("$INSTALLED_HELPER" --version)" == "OuroWorkbenchRemote 0.1.0" ]] || { printf 'Herdr integration smoke failed: installed helper probe failed\n' >&2; exit 1; }
[[ "$(/bin/cat "$RUNTIME_ROOT/current")" == "$REVISION" ]] || { printf 'Herdr integration smoke failed: current revision was not promoted\n' >&2; exit 1; }
ROLLBACK_OUTPUT="$("$INTEGRATION_DIR/static/uninstall.sh" "$APP_DIR" "$RUNTIME_ROOT")"
[[ "$ROLLBACK_OUTPUT" == *'retainedForNativeResume'* ]] || { printf 'Herdr integration smoke failed: current runtime was not safely retained\n' >&2; exit 1; }

printf 'Herdr integration bundle smoke ok\n'
