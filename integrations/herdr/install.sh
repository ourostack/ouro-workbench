#!/bin/bash
set -euo pipefail

usage() {
  printf 'Usage: %s [APP_PATH] [RUNTIME_ROOT]\n' "$(basename "$0")" >&2
}

if [[ $# -gt 2 ]]; then
  usage
  exit 64
fi

APP_DIR="${1:-/Applications/Ouro Workbench.app}"
RUNTIME_ROOT="${2:-$HOME/.local/share/ouro-mobile-control-plane/runtime/workbench}"
INTEGRATION_DIR="$APP_DIR/Contents/Resources/integrations/herdr"
STATIC_DIR="$INTEGRATION_DIR/static"
ARTIFACT_ROOT="$INTEGRATION_DIR/runtime"
MANIFEST="$ARTIFACT_ROOT/manifest.json"

/usr/bin/codesign --verify --deep --strict "$APP_DIR"
(cd "$STATIC_DIR" && /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null)

REVISION="$(/usr/bin/plutil -extract revision raw -o - "$MANIFEST")"
HELPER_RELATIVE="$(/usr/bin/plutil -extract files.0.relativePath raw -o - "$MANIFEST")"
EXPECTED_HELPER_SHA256="$(/usr/bin/plutil -extract files.0.sha256 raw -o - "$MANIFEST")"
[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || { printf 'Invalid bundled Remote revision\n' >&2; exit 1; }
[[ "$HELPER_RELATIVE" == "bin/OuroWorkbenchRemote" ]] || { printf 'Invalid bundled Remote helper path\n' >&2; exit 1; }
[[ "$EXPECTED_HELPER_SHA256" =~ ^[0-9a-f]{64}$ ]] || { printf 'Invalid bundled Remote helper digest\n' >&2; exit 1; }
HELPER="$ARTIFACT_ROOT/$HELPER_RELATIVE"

exec "$HELPER" install --runtime-root "$RUNTIME_ROOT" --artifact-root "$ARTIFACT_ROOT" --revision "$REVISION" --expected-helper-sha256 "$EXPECTED_HELPER_SHA256"
