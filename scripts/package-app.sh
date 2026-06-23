#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$("$ROOT_DIR/scripts/read-workbench-release.sh")"
APP_NAME="$WORKBENCH_APP_NAME"
PRODUCT_NAME="$WORKBENCH_BUNDLE_EXECUTABLE"
MCP_PRODUCT_NAME="$WORKBENCH_MCP_EXECUTABLE"
BUNDLE_ID="$WORKBENCH_BUNDLE_IDENTIFIER"
MINIMUM_MACOS_VERSION="$WORKBENCH_MINIMUM_MACOS_VERSION"
VERSION_FILE="$ROOT_DIR/VERSION"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
TOOLS_DIR="$MACOS_DIR/Tools"
SCREEN_SOURCE="/usr/bin/screen"
SWIFTTERM_BUNDLE_NAME="SwiftTerm_SwiftTerm.bundle"
APP_ICON_NAME="$PRODUCT_NAME.icns"
SWIFT_STRICT_FLAGS=(-Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete)

cd "$ROOT_DIR"

patch_swiftterm_resource_lookup() {
  local renderer="$ROOT_DIR/.build/checkouts/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift"
  local marker='Bundle(path: resourceURL.appendingPathComponent("SwiftTerm_SwiftTerm.bundle").path)'
  local temp_file

  # SwiftPM's generated Bundle.module accessor expects this resource bundle at
  # the .app root. macOS app bundles with root-level payloads cannot be sealed,
  # so packaged builds point SwiftTerm at Contents/Resources instead.
  if [[ ! -f "$renderer" ]]; then
    printf 'Required SwiftTerm renderer source is missing: %s\n' "$renderer" >&2
    exit 1
  fi

  if grep -F "$marker" "$renderer" >/dev/null; then
    return
  fi

  temp_file="$(mktemp)"
  if ! perl -0pe '
    BEGIN {
      $old = qq{        #if SWIFT_PACKAGE\n        bundles.append(Bundle.module)\n        #endif\n};
      $new = qq{        if let resourceURL = Bundle.main.resourceURL,\n           let bundle = Bundle(path: resourceURL.appendingPathComponent("SwiftTerm_SwiftTerm.bundle").path) {\n            bundles.append(bundle)\n        }\n};
    }
    $count = s/\Q$old\E/$new/;
    END { exit($count == 1 ? 0 : 1) }
  ' "$renderer" > "$temp_file"; then
    rm -f "$temp_file"
    printf 'Unable to patch SwiftTerm resource lookup for signable app packaging.\n' >&2
    printf 'The expected Bundle.module block was not found in %s\n' "$renderer" >&2
    exit 1
  fi

  mv "$temp_file" "$renderer"
}

VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ ! "$VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+([-.][0-9A-Za-z.]+)?$ ]]; then
  printf 'Invalid app version in %s: %s\n' "$VERSION_FILE" "$VERSION" >&2
  exit 1
fi
if [[ "$VERSION" != "$WORKBENCH_VERSION" ]]; then
  printf 'VERSION (%s) does not match WorkbenchRelease.version (%s)\n' "$VERSION" "$WORKBENCH_VERSION" >&2
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

swift package resolve
patch_swiftterm_resource_lookup
swift build -c release "${SWIFT_STRICT_FLAGS[@]}" --product "$PRODUCT_NAME"
swift build -c release "${SWIFT_STRICT_FLAGS[@]}" --product "$MCP_PRODUCT_NAME"
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
ditto "$SWIFTTERM_BUNDLE" "$RESOURCES_DIR/$SWIFTTERM_BUNDLE_NAME"

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
  <string>$PRODUCT_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MINIMUM_MACOS_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <key>NSSupportsSuddenTermination</key>
  <false/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "$APP_DIR"
