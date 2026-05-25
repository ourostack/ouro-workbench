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

cd "$ROOT_DIR"

VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ ! "$VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+([-.][0-9A-Za-z.]+)?$ ]]; then
  printf 'Invalid app version in %s: %s\n' "$VERSION_FILE" "$VERSION" >&2
  exit 1
fi
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || true)"
if [[ -z "$BUILD_NUMBER" || ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  BUILD_NUMBER="1"
fi

swift build -c release --product "$PRODUCT_NAME"
swift build -c release --product "$MCP_PRODUCT_NAME"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$TOOLS_DIR"

cp "$ROOT_DIR/.build/release/$PRODUCT_NAME" "$MACOS_DIR/$PRODUCT_NAME"
chmod 755 "$MACOS_DIR/$PRODUCT_NAME"
cp "$ROOT_DIR/.build/release/$MCP_PRODUCT_NAME" "$MACOS_DIR/$MCP_PRODUCT_NAME"
chmod 755 "$MACOS_DIR/$MCP_PRODUCT_NAME"

if [[ ! -x "$SCREEN_SOURCE" ]]; then
  printf 'Required terminal persistence backend is missing: %s\n' "$SCREEN_SOURCE" >&2
  exit 1
fi
cp "$SCREEN_SOURCE" "$TOOLS_DIR/screen"
chmod 755 "$TOOLS_DIR/screen"

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
