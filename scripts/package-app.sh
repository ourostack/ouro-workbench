#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Ouro Workbench"
PRODUCT_NAME="OuroWorkbench"
MCP_PRODUCT_NAME="OuroWorkbenchMCP"
VERSION_FILE="$ROOT_DIR/VERSION"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
TOOLS_DIR="$MACOS_DIR/Tools"
SCREEN_SOURCE="/usr/bin/screen"
SWIFTTERM_BUNDLE_NAME="SwiftTerm_SwiftTerm.bundle"
APP_ICON_NAME="OuroWorkbench.icns"

cd "$ROOT_DIR"

VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ ! "$VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+([-.][0-9A-Za-z.]+)?$ ]]; then
  printf 'Invalid app version in %s: %s\n' "$VERSION_FILE" "$VERSION" >&2
  exit 1
fi
BUILD_NUMBER="1"
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IS_SHALLOW="$(git -C "$ROOT_DIR" rev-parse --is-shallow-repository 2>/dev/null || printf 'false')"
  if [[ "$IS_SHALLOW" == "true" ]]; then
    printf 'Cannot derive bundle build number from a shallow git checkout.\n' >&2
    printf 'Fetch full history before packaging the app bundle.\n' >&2
    exit 1
  fi

  BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || true)"
  if [[ -z "$BUILD_NUMBER" || ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    printf 'Unable to derive numeric bundle build number from git history.\n' >&2
    exit 1
  fi
fi

swift build -c release --product "$PRODUCT_NAME"
swift build -c release --product "$MCP_PRODUCT_NAME"
SWIFTTERM_BUNDLE="$(find "$ROOT_DIR/.build" -path "*/release/$SWIFTTERM_BUNDLE_NAME" -type d -print -quit)"
if [[ -z "$SWIFTTERM_BUNDLE" ]]; then
  printf 'Required SwiftTerm resource bundle is missing from release build\n' >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$TOOLS_DIR"

cp "$ROOT_DIR/.build/release/$PRODUCT_NAME" "$MACOS_DIR/$PRODUCT_NAME"
chmod 755 "$MACOS_DIR/$PRODUCT_NAME"
cp "$ROOT_DIR/.build/release/$MCP_PRODUCT_NAME" "$MACOS_DIR/$MCP_PRODUCT_NAME"
chmod 755 "$MACOS_DIR/$MCP_PRODUCT_NAME"
cp "$ROOT_DIR/scripts/collect-support-diagnostics.sh" "$RESOURCES_DIR/collect-support-diagnostics.sh"
chmod 755 "$RESOURCES_DIR/collect-support-diagnostics.sh"
ditto "$SWIFTTERM_BUNDLE" "$APP_DIR/$SWIFTTERM_BUNDLE_NAME"

if [[ ! -x "$SCREEN_SOURCE" ]]; then
  printf 'Required terminal persistence backend is missing: %s\n' "$SCREEN_SOURCE" >&2
  exit 1
fi
cp "$SCREEN_SOURCE" "$TOOLS_DIR/screen"
chmod 755 "$TOOLS_DIR/screen"

swift "$ROOT_DIR/scripts/generate-app-icon.swift" "$RESOURCES_DIR/$APP_ICON_NAME" >/dev/null

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>OuroWorkbench</string>
  <key>CFBundleIdentifier</key>
  <string>com.ourostack.workbench</string>
  <key>CFBundleIconFile</key>
  <string>OuroWorkbench</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Ouro Workbench</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <key>NSSupportsSuddenTermination</key>
  <false/>
</dict>
</plist>
PLIST

echo "$APP_DIR"
