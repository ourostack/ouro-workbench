#!/usr/bin/env bash
#
# Ouro Workbench — one-line installer.
#
#   curl -fsSL https://ouro.bot/workbench-install.sh | bash
#
# Self-contained: needs only tools present on a stock macOS. No git checkout,
# no GitHub CLI, no jq/python. Downloads the latest published release artifact,
# verifies it against the release manifest, stages and verifies the app bundle,
# replaces the previous install with rollback on failure, clears the download
# quarantine, and opens it.
#
# Env overrides:
#   OURO_WB_REPO         GitHub owner/repo        (default: ourostack/ouro-workbench)
#   OURO_WB_INSTALL_DIR  install destination dir  (default: ~/Applications)
#   OURO_WB_NO_OPEN=1    don't open the app after installing
set -euo pipefail

REPO="${OURO_WB_REPO:-ourostack/ouro-workbench}"
INSTALL_DIR="${OURO_WB_INSTALL_DIR:-$HOME/Applications}"
API="https://api.github.com/repos/${REPO}/releases?per_page=1"
APP_NAME="Ouro Workbench"
APP_BUNDLE="$APP_NAME.app"
EXPECTED_BUNDLE_ID="com.ourostack.workbench"
EXPECTED_EXECUTABLE="OuroWorkbench"
MCP_EXECUTABLE="OuroWorkbenchMCP"
MCP_SERVER_NAME="ouro-workbench"
EXPECTED_MINIMUM_MACOS="14.0"
EXPECTED_ARTIFACT_PREFIX="$EXPECTED_EXECUTABLE-"

say()  { printf '\033[1;36m▸\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$1" >&2; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Ouro Workbench is macOS-only (this is $(uname -s))."
if [ "$(uname -m)" != "arm64" ]; then
  warn "Builds are Apple Silicon (arm64); on this $(uname -m) Mac the app may not launch."
fi
for tool in curl shasum ditto plutil codesign pgrep ps osascript; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done
[ -x /usr/libexec/PlistBuddy ] || die "required tool not found: /usr/libexec/PlistBuddy"

tmp=""
install_staging=""
backup_app=""
dest=""
install_succeeded="false"
destination_replaced="false"

restore_previous_install() {
  if [ "$install_succeeded" = "true" ]; then
    return 0
  fi
  if [ -n "$backup_app" ] && [ -d "$backup_app" ]; then
    rm -rf "$dest"
    mv "$backup_app" "$dest"
  elif [ "$destination_replaced" = "true" ] && [ -n "$dest" ]; then
    rm -rf "$dest"
  fi
}

cleanup() {
  restore_previous_install
  [ -z "$tmp" ] || rm -rf "$tmp"
  [ -z "$install_staging" ] || rm -rf "$install_staging"
}

trap cleanup EXIT

running_workbench_pids_for_destination() {
  local pid
  local command
  for pid in $(pgrep -x "$EXPECTED_EXECUTABLE" 2>/dev/null || true); do
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$command" in
      "$dest/Contents/MacOS/$EXPECTED_EXECUTABLE"*)
        printf '%s\n' "$pid"
        ;;
    esac
  done
}

destination_workbench_is_running() {
  [ -n "$(running_workbench_pids_for_destination)" ]
}

wait_until_workbench_stops() {
  local _
  for _ in $(seq 1 40); do
    if ! destination_workbench_is_running; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

stop_running_workbench() {
  if ! destination_workbench_is_running; then
    return
  fi

  say "Stopping running $APP_NAME before install..."
  osascript -e "tell application id \"$EXPECTED_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  if wait_until_workbench_stops; then
    return
  fi

  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    kill -TERM "$pid" >/dev/null 2>&1 || true
  done <<PIDS
$(running_workbench_pids_for_destination)
PIDS
  wait_until_workbench_stops || die "unable to stop running $APP_NAME before install."
}

manifest_string_value() {
  local key="$1"
  printf '%s' "$manifest" | grep -o "\"$key\": *\"[^\"]*\"" | sed 's/.*: *"\([^"]*\)".*/\1/' | head -1 || true
}

manifest_bool_value() {
  local key="$1"
  printf '%s' "$manifest" | grep -Eo "\"$key\": *(true|false)" | sed -E 's/.*: *(true|false).*/\1/' | head -1 || true
}

plist_value() {
  local info_plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$info_plist" 2>/dev/null
}

run_gui_smoke() {
  local executable_path="$1"
  local output_file
  local smoke_pid
  local smoke_output
  local status
  local _

  output_file="$(mktemp "${TMPDIR:-/tmp}/ouro-workbench-web-smoke.XXXXXX")"
  "$executable_path" --smoke-launch >"$output_file" 2>&1 &
  smoke_pid=$!

  for _ in $(seq 1 10); do
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
    die "GUI launch smoke timed out: $smoke_output"
  fi

  if wait "$smoke_pid"; then
    status=0
  else
    status=$?
  fi
  smoke_output="$(cat "$output_file")"
  rm -f "$output_file"

  [ "$status" -eq 0 ] || die "GUI launch smoke failed: $smoke_output"
  printf '%s' "$smoke_output" | grep -F "OuroWorkbench smoke launch ok" >/dev/null \
    || die "GUI launch smoke did not report success"
}

verify_app_bundle() {
  local app_path="$1"
  local expected_version="$2"
  local expected_build="$3"
  local contents_dir="$app_path/Contents"
  local macos_dir="$contents_dir/MacOS"
  local resources_dir="$contents_dir/Resources"
  local info_plist="$app_path/Contents/Info.plist"
  local executable_path="$macos_dir/$EXPECTED_EXECUTABLE"
  local mcp_executable="$macos_dir/$MCP_EXECUTABLE"
  local screen_executable="$macos_dir/Tools/screen"
  local support_diagnostics_script="$resources_dir/collect-support-diagnostics.sh"
  local app_icon="$resources_dir/$EXPECTED_EXECUTABLE.icns"
  local swiftterm_bundle="$resources_dir/SwiftTerm_SwiftTerm.bundle"
  local mcp_initialize

  [ -d "$app_path" ] || die "app bundle is missing: $app_path"
  [ -f "$info_plist" ] || die "Info.plist is missing from $app_path"
  plutil -lint "$info_plist" >/dev/null || die "Info.plist is invalid in $app_path"

  [ "$(plist_value "$info_plist" CFBundleIdentifier)" = "$EXPECTED_BUNDLE_ID" ] \
    || die "unexpected bundle identifier in $app_path"
  [ "$(plist_value "$info_plist" CFBundleExecutable)" = "$EXPECTED_EXECUTABLE" ] \
    || die "unexpected bundle executable in $app_path"
  [ "$(plist_value "$info_plist" CFBundlePackageType)" = "APPL" ] \
    || die "unexpected bundle package type in $app_path"
  [ "$(plist_value "$info_plist" CFBundleShortVersionString)" = "$expected_version" ] \
    || die "unexpected bundle version in $app_path"
  [ "$(plist_value "$info_plist" CFBundleVersion)" = "$expected_build" ] \
    || die "unexpected bundle build in $app_path"
  [ "$(plist_value "$info_plist" LSMinimumSystemVersion)" = "$EXPECTED_MINIMUM_MACOS" ] \
    || die "unexpected minimum macOS version in $app_path"
  [ -x "$executable_path" ] || die "app executable is missing or not executable in $app_path"
  [ -x "$mcp_executable" ] || die "MCP executable is missing or not executable in $app_path"
  [ -x "$screen_executable" ] || die "screen helper is missing or not executable in $app_path"
  [ -x "$support_diagnostics_script" ] || die "support diagnostics helper is missing or not executable in $app_path"
  [ -s "$support_diagnostics_script" ] || die "support diagnostics helper is empty in $app_path"
  "$support_diagnostics_script" --help >/dev/null \
    || die "support diagnostics helper does not run in $app_path"
  [ -s "$app_icon" ] || die "app icon is missing or empty in $app_path"
  [ -d "$swiftterm_bundle" ] || die "SwiftTerm resource bundle is missing in $app_path"
  [ ! -e "$app_path/SwiftTerm_SwiftTerm.bundle" ] || die "SwiftTerm bundle is at app root in $app_path"

  run_gui_smoke "$executable_path"

  codesign --verify --deep --strict --verbose=2 "$app_path" >/dev/null 2>&1 \
    || die "app bundle code signature does not verify: $app_path"

  mcp_initialize="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | "$mcp_executable")" \
    || die "MCP initialize failed in $app_path"
  printf '%s' "$mcp_initialize" | grep -F "\"name\":\"$MCP_SERVER_NAME\"" >/dev/null \
    || die "MCP initialize does not report $MCP_SERVER_NAME in $app_path"
  printf '%s' "$mcp_initialize" | grep -F "\"version\":\"$expected_version\"" >/dev/null \
    || die "MCP initialize does not report version $expected_version in $app_path"
}

select_release_assets() {
  local asset_urls
  local candidate
  local asset_name
  local canonical_zip_pattern
  local canonical_manifest_pattern
  local all_zip_count=0
  local all_manifest_count=0
  local canonical_zip_count=0
  local canonical_manifest_count=0

  zip_url=""
  manifest_url=""
  canonical_zip_pattern="${EXPECTED_ARTIFACT_PREFIX}*-build.*-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].zip"
  canonical_manifest_pattern="${EXPECTED_ARTIFACT_PREFIX}*-build.*-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].manifest.json"
  asset_urls="$(printf '%s' "$rel" | grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*"\(https[^"]*\)"/\1/' || true)"

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    asset_name="$(basename "$candidate")"
    case "$asset_name" in
      *.manifest.json)
        all_manifest_count=$((all_manifest_count + 1))
        case "$asset_name" in
          $canonical_manifest_pattern)
            manifest_url="$candidate"
            canonical_manifest_count=$((canonical_manifest_count + 1))
            ;;
        esac
        ;;
      *.zip)
        all_zip_count=$((all_zip_count + 1))
        case "$asset_name" in
          $canonical_zip_pattern)
            zip_url="$candidate"
            canonical_zip_count=$((canonical_zip_count + 1))
            ;;
        esac
        ;;
    esac
  done <<ASSET_URLS
$asset_urls
ASSET_URLS

  [ "$all_zip_count" -eq 1 ] || die "expected exactly one public .zip asset, found $all_zip_count."
  [ "$all_manifest_count" -eq 1 ] || die "expected exactly one public .manifest.json asset, found $all_manifest_count."
  [ "$canonical_zip_count" -eq 1 ] || die "expected exactly one canonical $EXPECTED_ARTIFACT_PREFIX zip asset, found $canonical_zip_count."
  [ "$canonical_manifest_count" -eq 1 ] || die "expected exactly one canonical $EXPECTED_ARTIFACT_PREFIX manifest asset, found $canonical_manifest_count."
}

say "Finding the latest Ouro Workbench release…"
rel="$(curl -fsSL "$API")" || die "couldn't reach the GitHub release API."

select_release_assets
zip_name="$(basename "$zip_url")"
manifest_name="$(basename "$manifest_url")"
[ "$manifest_name" = "${zip_name%.zip}.manifest.json" ] \
  || die "manifest asset does not match archive asset."

tmp="$(mktemp -d)"
zip_path="$tmp/$zip_name"

say "Downloading ${zip_name}..."
curl -fsSL "$zip_url" -o "$zip_path" || die "download failed."
manifest="$(curl -fsSL "$manifest_url")" || die "couldn't fetch the release manifest."

manifest_app_name="$(manifest_string_value appName)"
manifest_bundle_id="$(manifest_string_value bundleIdentifier)"
manifest_version="$(manifest_string_value version)"
manifest_build="$(manifest_string_value build)"
manifest_archive="$(manifest_string_value archive)"
manifest_git_sha="$(manifest_string_value gitSha)"
manifest_git_dirty="$(manifest_bool_value gitDirty)"
expected="$(manifest_string_value sha256)"
archive_short_sha="${zip_name%.zip}"
archive_short_sha="${archive_short_sha##*-}"
[ "$manifest_app_name" = "$APP_NAME" ] || die "manifest app name is not $APP_NAME."
[ "$manifest_bundle_id" = "$EXPECTED_BUNDLE_ID" ] || die "manifest bundle identifier is not $EXPECTED_BUNDLE_ID."
[ -n "$manifest_version" ] || die "manifest has no version to verify against."
[ -n "$manifest_build" ] || die "manifest has no build to verify against."
[ "$manifest_archive" = "$zip_name" ] || die "manifest archive does not match downloaded zip."
[ "$zip_name" = "$EXPECTED_ARTIFACT_PREFIX$manifest_version-build.$manifest_build-$archive_short_sha.zip" ] \
  || die "archive name does not match manifest version/build."
[ "$manifest_git_dirty" = "false" ] || die "manifest gitDirty is not false."
[ -n "$manifest_git_sha" ] || die "manifest has no gitSha to verify against."
case "$manifest_git_sha" in
  "$archive_short_sha"*) ;;
  *) die "manifest gitSha does not match archive short SHA." ;;
esac
[ -n "$expected" ] || die "manifest has no sha256 to verify against."
actual="$(shasum -a 256 "$zip_path" | awk '{print $1}')"
[ "$actual" = "$expected" ] || die "checksum mismatch (expected $expected, got $actual). Aborting."
say "Checksum verified."

say "Extracting…"
ditto -x -k "$zip_path" "$tmp/extracted"
app_src="$tmp/extracted/$APP_BUNDLE"
[ -d "$app_src" ] || die "archive does not contain $APP_BUNDLE at its root."
verify_app_bundle "$app_src" "$manifest_version" "$manifest_build"

mkdir -p "$INSTALL_DIR"
install_staging="$(mktemp -d "$INSTALL_DIR/.ouro-workbench-install.XXXXXX")"
staged_app="$install_staging/$APP_BUNDLE"
backup_app="$install_staging/previous-$APP_BUNDLE"
dest="$INSTALL_DIR/$APP_BUNDLE"

ditto "$app_src" "$staged_app"
verify_app_bundle "$staged_app" "$manifest_version" "$manifest_build"

stop_running_workbench

if [ -d "$dest" ]; then
  say "Replacing existing install at $dest"
  mv "$dest" "$backup_app"
fi
mv "$staged_app" "$dest"
destination_replaced="true"

# The download set the com.apple.quarantine xattr; the build is ad-hoc-signed
# (not yet notarized), so strip it to avoid the Gatekeeper "unidentified
# developer" / "damaged" prompt. lsregister refresh keeps Launch Services tidy.
xattr -cr "$dest" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$dest" >/dev/null 2>&1 || true
verify_app_bundle "$dest" "$manifest_version" "$manifest_build"
install_succeeded="true"
rm -rf "$backup_app"

say "Installed $APP_NAME ${manifest_version:-} → $dest"

if [ "${OURO_WB_NO_OPEN:-}" != "1" ]; then
  open "$dest" || warn "couldn't auto-open; launch it from $INSTALL_DIR."
fi

cat <<'NEXT'

Next:
  • Set up your boss agent and tools via "Set Up Workbench" (wand button / ⌘K).
  • Toggle "Open at Login" so it relaunches and recovers after a restart.
  • ⌘M backgrounds it (autonomy keeps running); ⌘W quits.
NEXT
