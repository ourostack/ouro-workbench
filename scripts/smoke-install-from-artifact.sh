#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ouro-workbench-install-artifact.XXXXXX")"
INSTALL_DIR="$TEMP_ROOT/Applications"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"

cleanup() {
  rm -rf "$TEMP_ROOT"
}

trap cleanup EXIT

latest_manifest="$(find "$ARTIFACTS_DIR" -name "OuroWorkbench-${VERSION}-*.manifest.json" -type f -print | sort | tail -n 1)"
if [[ -z "$latest_manifest" ]]; then
  printf 'Install-from-artifact smoke failed: no manifest found for version %s in %s\n' "$VERSION" "$ARTIFACTS_DIR" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
"$ROOT_DIR/scripts/install-app.sh" --install-dir "$INSTALL_DIR" --artifact-manifest "$latest_manifest" >/dev/null
"$ROOT_DIR/scripts/verify-app-bundle.sh" "$INSTALL_DIR/Ouro Workbench.app" >/dev/null

printf 'Install-from-artifact smoke passed\n'
