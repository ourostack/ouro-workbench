#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$("$ROOT_DIR/scripts/read-workbench-release.sh")"
MANIFEST_PATH=""
ARCHIVE_PATH=""
TEMP_ROOT=""

usage() {
  printf 'Usage: %s MANIFEST_PATH [ARCHIVE_PATH]\n' "$(basename "$0")" >&2
}

fail() {
  printf 'App artifact verification failed: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_ROOT" ]]; then
    rm -rf "$TEMP_ROOT"
  fi
}

trap cleanup EXIT

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 64
fi

MANIFEST_PATH="$1"
if [[ $# -eq 2 ]]; then
  ARCHIVE_PATH="$2"
fi

[[ -f "$MANIFEST_PATH" ]] || fail "missing manifest $MANIFEST_PATH"

manifest_value() {
  plutil -extract "$1" raw -o - "$MANIFEST_PATH"
}

archive_name="$(manifest_value archive)"
expected_app_name="$(manifest_value appName)"
expected_sha256="$(manifest_value sha256)"
expected_bytes="$(manifest_value bytes)"
expected_bundle_id="$(manifest_value bundleIdentifier)"
expected_version="$(manifest_value version)"
expected_build="$(manifest_value build)"
expected_dirty="$(manifest_value gitDirty 2>/dev/null || printf 'false')"

if [[ -z "$ARCHIVE_PATH" ]]; then
  ARCHIVE_PATH="$(dirname "$MANIFEST_PATH")/$archive_name"
fi

[[ -f "$ARCHIVE_PATH" ]] || fail "missing archive $ARCHIVE_PATH"
[[ "$(basename "$ARCHIVE_PATH")" == "$archive_name" ]] || fail "archive name does not match manifest"
[[ "$expected_app_name" == "$WORKBENCH_APP_NAME" ]] || fail "manifest app name does not match WorkbenchRelease"
[[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] || fail "manifest sha256 is not valid"
[[ "$expected_bytes" =~ ^[0-9]+$ ]] || fail "manifest byte count is not numeric"
[[ "$expected_build" =~ ^[0-9]+$ ]] || fail "manifest build is not numeric"
[[ "$expected_dirty" == "true" || "$expected_dirty" == "false" ]] || fail "manifest gitDirty is not boolean"
[[ "$expected_version" =~ ^[0-9]+[.][0-9]+[.][0-9]+([-.][0-9A-Za-z.]+)?$ ]] || fail "manifest version is not semver-like"

actual_sha256="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
[[ "$actual_sha256" == "$expected_sha256" ]] || fail "archive checksum mismatch"

actual_bytes="$(stat -f %z "$ARCHIVE_PATH")"
[[ "$actual_bytes" == "$expected_bytes" ]] || fail "archive byte count mismatch"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ouro-workbench-artifact.XXXXXX")"
ditto -x -k "$ARCHIVE_PATH" "$TEMP_ROOT"
EXTRACTED_APP="$TEMP_ROOT/$expected_app_name.app"
[[ -d "$EXTRACTED_APP" ]] || fail "archive does not expand to $expected_app_name.app"

"$ROOT_DIR/scripts/verify-app-bundle.sh" "$EXTRACTED_APP" --expected-version "$expected_version" >/dev/null

INFO_PLIST="$EXTRACTED_APP/Contents/Info.plist"
bundle_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"
}

[[ "$(bundle_value CFBundleIdentifier)" == "$expected_bundle_id" ]] || fail "bundle identifier does not match manifest"
[[ "$(bundle_value CFBundleShortVersionString)" == "$expected_version" ]] || fail "bundle version does not match manifest"
[[ "$(bundle_value CFBundleVersion)" == "$expected_build" ]] || fail "bundle build does not match manifest"

printf 'Verified app artifact: %s\n' "$ARCHIVE_PATH"
