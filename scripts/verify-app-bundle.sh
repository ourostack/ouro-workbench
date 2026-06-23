#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$("$ROOT_DIR/scripts/read-workbench-release.sh")"
VERSION_FILE="$ROOT_DIR/VERSION"
APP_DIR="$ROOT_DIR/dist/$WORKBENCH_APP_NAME.app"
EXPECTED_VERSION=""
GUI_SMOKE_TIMEOUT_SECONDS="10"

usage() {
  printf 'Usage: %s [APP_PATH] [--expected-version VERSION] [--gui-smoke-timeout SECONDS]\n' "$(basename "$0")" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected-version)
      if [[ $# -lt 2 || -z "$2" ]]; then
        usage
        exit 64
      fi
      EXPECTED_VERSION="$2"
      shift 2
      ;;
    --gui-smoke-timeout)
      if [[ $# -lt 2 || -z "$2" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
        usage
        exit 64
      fi
      GUI_SMOKE_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      usage
      exit 64
      ;;
    *)
      APP_DIR="$1"
      shift
      ;;
  esac
done

CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
APP_EXECUTABLE="$MACOS_DIR/$WORKBENCH_BUNDLE_EXECUTABLE"
MCP_EXECUTABLE="$MACOS_DIR/$WORKBENCH_MCP_EXECUTABLE"
SCREEN_EXECUTABLE="$MACOS_DIR/Tools/screen"
SUPPORT_DIAGNOSTICS_SCRIPT="$RESOURCES_DIR/collect-support-diagnostics.sh"
APP_ICON="$RESOURCES_DIR/$WORKBENCH_BUNDLE_EXECUTABLE.icns"
SWIFTTERM_BUNDLE="$RESOURCES_DIR/SwiftTerm_SwiftTerm.bundle"

fail() {
  printf 'App bundle verification failed: %s\n' "$1" >&2
  exit 1
}

require_executable() {
  local path="$1"
  [[ -f "$path" ]] || fail "missing executable $path"
  [[ -x "$path" ]] || fail "not executable $path"
}

run_gui_smoke() {
  local output_file
  local smoke_pid
  local smoke_output
  local status
  local timeout_seconds="$GUI_SMOKE_TIMEOUT_SECONDS"

  output_file="$(mktemp)"
  "$APP_EXECUTABLE" --smoke-launch >"$output_file" 2>&1 &
  smoke_pid=$!

  for _ in $(seq 1 "$timeout_seconds"); do
    if ! kill -0 "$smoke_pid" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  if kill -0 "$smoke_pid" 2>/dev/null; then
    kill "$smoke_pid" 2>/dev/null || true
    wait "$smoke_pid" 2>/dev/null || true
    smoke_output="$(cat "$output_file")"
    rm -f "$output_file"
    fail "GUI launch smoke timed out after ${timeout_seconds}s: $smoke_output"
  fi

  if wait "$smoke_pid"; then
    status=0
  else
    status=$?
  fi
  smoke_output="$(cat "$output_file")"
  rm -f "$output_file"

  [[ "$status" -eq 0 ]] || fail "GUI launch smoke failed: $smoke_output"
  if ! grep -F "OuroWorkbench smoke launch ok" <<<"$smoke_output" >/dev/null; then
    fail "GUI launch smoke did not report success"
  fi
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"
}

[[ -d "$APP_DIR" ]] || fail "missing app bundle $APP_DIR"
[[ -f "$INFO_PLIST" ]] || fail "missing Info.plist"
plutil -lint "$INFO_PLIST" >/dev/null

[[ "$(plist_value CFBundleIdentifier)" == "$WORKBENCH_BUNDLE_IDENTIFIER" ]] || fail "unexpected bundle identifier"
[[ "$(plist_value CFBundleExecutable)" == "$WORKBENCH_BUNDLE_EXECUTABLE" ]] || fail "unexpected bundle executable"
[[ "$(plist_value CFBundleIconFile)" == "$WORKBENCH_BUNDLE_EXECUTABLE" ]] || fail "unexpected bundle icon"
[[ "$(plist_value CFBundlePackageType)" == "APPL" ]] || fail "unexpected bundle package type"
source_version="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$source_version" == "$WORKBENCH_VERSION" ]] || fail "VERSION does not match WorkbenchRelease.version"
expected_version="${EXPECTED_VERSION:-$WORKBENCH_VERSION}"
[[ "$(plist_value CFBundleShortVersionString)" == "$expected_version" ]] || fail "unexpected bundle version"
[[ "$(plist_value CFBundleVersion)" =~ ^[0-9]+$ ]] || fail "bundle build number is not numeric"
[[ "$(plist_value LSMinimumSystemVersion)" == "$WORKBENCH_MINIMUM_MACOS_VERSION" ]] || fail "unexpected minimum macOS version"

require_executable "$APP_EXECUTABLE"
require_executable "$MCP_EXECUTABLE"
require_executable "$SCREEN_EXECUTABLE"
require_executable "$SUPPORT_DIAGNOSTICS_SCRIPT"
[[ "$(stat -f %z "$SUPPORT_DIAGNOSTICS_SCRIPT")" -gt 0 ]] || fail "empty support diagnostics helper"
"$SUPPORT_DIAGNOSTICS_SCRIPT" --help >/dev/null
[[ -f "$APP_ICON" ]] || fail "missing app icon"
[[ "$(stat -f %z "$APP_ICON")" -gt 0 ]] || fail "empty app icon"
[[ -d "$SWIFTTERM_BUNDLE" ]] || fail "missing SwiftTerm resource bundle"
[[ ! -e "$APP_DIR/SwiftTerm_SwiftTerm.bundle" ]] || fail "SwiftTerm resource bundle must not be placed at app bundle root"

run_gui_smoke

if ! codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null 2>&1; then
  fail "app bundle code signature does not verify"
fi

mcp_initialize="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | "$MCP_EXECUTABLE")"
if ! grep -F "\"name\":\"$WORKBENCH_MCP_SERVER_NAME\"" <<<"$mcp_initialize" >/dev/null; then
  fail "MCP initialize does not report $WORKBENCH_MCP_SERVER_NAME server name"
fi
if ! grep -F "\"version\":\"$expected_version\"" <<<"$mcp_initialize" >/dev/null; then
  fail "MCP initialize does not report version $expected_version"
fi

for binary in "$APP_EXECUTABLE" "$MCP_EXECUTABLE"; do
  if otool -L "$binary" | tail -n +2 | grep -E "$ROOT_DIR|\\.build|DerivedData" >/dev/null; then
    fail "$binary links against a local build path"
  fi
done

printf 'Verified app bundle: %s\n' "$APP_DIR"
