#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_SOURCE="$ROOT_DIR/Sources/OuroWorkbenchCore/WorkbenchRelease.swift"

fail() {
  printf 'Workbench release contract read failed: %s\n' "$1" >&2
  exit 1
}

read_const() {
  local name="$1"
  sed -n 's/^[[:space:]]*public static let '"$name"' = "\(.*\)"[[:space:]]*$/\1/p' "$RELEASE_SOURCE" | head -n 1
}

emit() {
  local name="$1"
  local value="$2"
  [[ -n "$value" ]] || fail "missing WorkbenchRelease.$name"
  printf 'WORKBENCH_%s=%q\n' "$name" "$value"
}

[[ -f "$RELEASE_SOURCE" ]] || fail "missing $RELEASE_SOURCE"

app_name="$(read_const appName)"
bundle_identifier="$(read_const bundleIdentifier)"
bundle_executable="$(read_const bundleExecutable)"
mcp_executable="$(read_const mcpExecutable)"
mcp_server_name="$(read_const mcpServerName)"
artifact_name_prefix="$(read_const artifactNamePrefix)"
version="$(read_const version)"
repository="$(read_const repository)"
minimum_macos_version="$(read_const minimumMacOSVersion)"

if [[ "$artifact_name_prefix" == "\\(bundleExecutable)-" ]]; then
  artifact_name_prefix="$bundle_executable-"
fi

emit APP_NAME "$app_name"
emit BUNDLE_IDENTIFIER "$bundle_identifier"
emit BUNDLE_EXECUTABLE "$bundle_executable"
emit MCP_EXECUTABLE "$mcp_executable"
emit MCP_SERVER_NAME "$mcp_server_name"
emit ARTIFACT_NAME_PREFIX "$artifact_name_prefix"
emit VERSION "$version"
emit REPOSITORY "$repository"
emit MINIMUM_MACOS_VERSION "$minimum_macos_version"
