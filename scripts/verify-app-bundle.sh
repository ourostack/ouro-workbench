#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${1:-"$ROOT_DIR/dist/Ouro Workbench.app"}"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
APP_EXECUTABLE="$MACOS_DIR/OuroWorkbench"
MCP_EXECUTABLE="$MACOS_DIR/OuroWorkbenchMCP"
SCREEN_EXECUTABLE="$MACOS_DIR/Tools/screen"

fail() {
  printf 'App bundle verification failed: %s\n' "$1" >&2
  exit 1
}

require_executable() {
  local path="$1"
  [[ -f "$path" ]] || fail "missing executable $path"
  [[ -x "$path" ]] || fail "not executable $path"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"
}

[[ -d "$APP_DIR" ]] || fail "missing app bundle $APP_DIR"
[[ -f "$INFO_PLIST" ]] || fail "missing Info.plist"
plutil -lint "$INFO_PLIST" >/dev/null

[[ "$(plist_value CFBundleIdentifier)" == "com.ourostack.workbench" ]] || fail "unexpected bundle identifier"
[[ "$(plist_value CFBundleExecutable)" == "OuroWorkbench" ]] || fail "unexpected bundle executable"
[[ "$(plist_value CFBundlePackageType)" == "APPL" ]] || fail "unexpected bundle package type"
[[ "$(plist_value LSMinimumSystemVersion)" == "14.0" ]] || fail "unexpected minimum macOS version"

require_executable "$APP_EXECUTABLE"
require_executable "$MCP_EXECUTABLE"
require_executable "$SCREEN_EXECUTABLE"

for binary in "$APP_EXECUTABLE" "$MCP_EXECUTABLE"; do
  if otool -L "$binary" | tail -n +2 | grep -E "$ROOT_DIR|\\.build|DerivedData" >/dev/null; then
    fail "$binary links against a local build path"
  fi
done

printf 'Verified app bundle: %s\n' "$APP_DIR"
