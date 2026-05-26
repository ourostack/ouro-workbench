#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEMP_ROOT"' EXIT

APP_DIR="$TEMP_ROOT/Ouro Workbench.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
mkdir -p "$MACOS_DIR/Tools" "$RESOURCES_DIR" "$APP_DIR/SwiftTerm_SwiftTerm.bundle"

version="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>OuroWorkbench</string>
  <key>CFBundleIdentifier</key>
  <string>com.ourostack.workbench</string>
  <key>CFBundleIconFile</key>
  <string>OuroWorkbench</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$version</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
</dict>
</plist>
PLIST

printf 'fake icon for timeout smoke\n' > "$RESOURCES_DIR/OuroWorkbench.icns"

cat > "$MACOS_DIR/OuroWorkbench" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--smoke-launch" ]]; then
  trap 'exit 0' TERM
  while true; do
    sleep 1
  done
fi
exit 1
SH

cat > "$MACOS_DIR/OuroWorkbenchMCP" <<SH
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"ouro-workbench","version":"$version"}}}'
SH

cat > "$MACOS_DIR/Tools/screen" <<'SH'
#!/usr/bin/env bash
exit 0
SH

chmod +x "$MACOS_DIR/OuroWorkbench" "$MACOS_DIR/OuroWorkbenchMCP" "$MACOS_DIR/Tools/screen"

cat > "$RESOURCES_DIR/collect-support-diagnostics.sh" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]]; then
  exit 0
fi
printf 'Wrote diagnostics: /tmp/fake.zip\n'
SH

chmod +x "$RESOURCES_DIR/collect-support-diagnostics.sh"

set +e
"$ROOT_DIR/scripts/verify-app-bundle.sh" "$APP_DIR" --gui-smoke-timeout 1 >"$TEMP_ROOT/stdout.log" 2>"$TEMP_ROOT/stderr.log"
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  printf 'Expected app bundle verifier to reject a hanging GUI smoke launch.\n' >&2
  exit 1
fi

if ! grep -q 'GUI launch smoke timed out' "$TEMP_ROOT/stderr.log"; then
  printf 'Expected GUI smoke timeout error, got:\n' >&2
  cat "$TEMP_ROOT/stderr.log" >&2
  exit 1
fi

printf 'app bundle GUI smoke timeout guard ok\n'
