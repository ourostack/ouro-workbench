#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
PACKAGE_SOURCE="$ROOT_DIR/Package.swift"
eval "$("$ROOT_DIR/scripts/read-workbench-release.sh")"

fail() {
  printf 'Version contract verification failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "$VERSION_FILE" ]] || fail "missing VERSION file"
version="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+([-.][0-9A-Za-z.]+)?$ ]] || fail "VERSION is not semver-like: $version"

[[ "$WORKBENCH_VERSION" == "$version" ]] || fail "WorkbenchRelease.version is $WORKBENCH_VERSION, expected $version"
[[ "$WORKBENCH_BUNDLE_IDENTIFIER" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]] || fail "bundle identifier is not identifier-like: $WORKBENCH_BUNDLE_IDENTIFIER"
[[ "$WORKBENCH_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "repository is not owner/repo: $WORKBENCH_REPOSITORY"
[[ "$WORKBENCH_ARTIFACT_NAME_PREFIX" == "$WORKBENCH_BUNDLE_EXECUTABLE-" ]] || fail "artifact prefix does not derive from bundle executable"
[[ "$WORKBENCH_MINIMUM_MACOS_VERSION" =~ ^[0-9]+[.][0-9]+$ ]] || fail "minimum macOS version is not major.minor: $WORKBENCH_MINIMUM_MACOS_VERSION"

grep -F ".executable(name: \"$WORKBENCH_BUNDLE_EXECUTABLE\"" "$PACKAGE_SOURCE" >/dev/null \
  || fail "Package.swift does not expose executable $WORKBENCH_BUNDLE_EXECUTABLE"
grep -F ".executable(name: \"$WORKBENCH_MCP_EXECUTABLE\"" "$PACKAGE_SOURCE" >/dev/null \
  || fail "Package.swift does not expose executable $WORKBENCH_MCP_EXECUTABLE"

if [[ -f "$ROOT_DIR/web/workbench-install.sh" ]]; then
  grep -F "OURO_WB_REPO:-$WORKBENCH_REPOSITORY" "$ROOT_DIR/web/workbench-install.sh" >/dev/null \
    || fail "web installer default repository does not match WorkbenchRelease.repository"
  grep -F "APP_NAME=\"$WORKBENCH_APP_NAME\"" "$ROOT_DIR/web/workbench-install.sh" >/dev/null \
    || fail "web installer app name does not match WorkbenchRelease.appName"
  grep -F "EXPECTED_BUNDLE_ID=\"$WORKBENCH_BUNDLE_IDENTIFIER\"" "$ROOT_DIR/web/workbench-install.sh" >/dev/null \
    || fail "web installer bundle id does not match WorkbenchRelease.bundleIdentifier"
  grep -F "EXPECTED_EXECUTABLE=\"$WORKBENCH_BUNDLE_EXECUTABLE\"" "$ROOT_DIR/web/workbench-install.sh" >/dev/null \
    || fail "web installer executable does not match WorkbenchRelease.bundleExecutable"
  grep -F "EXPECTED_MINIMUM_MACOS=\"$WORKBENCH_MINIMUM_MACOS_VERSION\"" "$ROOT_DIR/web/workbench-install.sh" >/dev/null \
    || fail "web installer minimum macOS does not match WorkbenchRelease.minimumMacOSVersion"
fi

printf 'Verified Workbench release contract: %s (%s, %s)\n' "$version" "$WORKBENCH_BUNDLE_IDENTIFIER" "$WORKBENCH_REPOSITORY"
