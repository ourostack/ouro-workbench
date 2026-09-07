#!/usr/bin/env bash
#
# Developer ID signs, notarizes, staples, and verifies a Workbench .app bundle.
set -euo pipefail

APP_PATH=""
APP_NAME=""
IDENTITY="${OURO_CODESIGN_IDENTITY:-${DEVELOPER_ID_APPLICATION:-}}"
NOTARY_PROFILE="${OURO_NOTARY_PROFILE:-}"
TMP_ROOT=""
REMOTE_ARTIFACT_RELATIVE="Contents/Resources/integrations/herdr/runtime"

usage() {
  cat >&2 <<'USAGE'
Usage:
  scripts/sign-notarize-app.sh --app PATH [--app-name NAME]
  scripts/sign-notarize-app.sh --selftest
USAGE
}

fail() {
  printf 'Signing/notarization failed: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TMP_ROOT" ]]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

have_all() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || return 1
  done
}

remote_manifest_value() {
  local manifest="$1"
  local key="$2"
  /usr/bin/plutil -extract "$key" raw -o - "$manifest" 2>/dev/null
}

verify_remote_manifest_digest() {
  local manifest="$1"
  local helper="$2"
  local expected_relative
  local expected_sha256
  local observed_sha256

  [[ -f "$manifest" ]] || fail "Herdr RemoteArtifact manifest is missing: $manifest"
  [[ -f "$helper" && -x "$helper" ]] || fail "Herdr RemoteArtifact helper is missing or not executable: $helper"
  expected_relative="$(remote_manifest_value "$manifest" files.0.relativePath)" \
    || fail "Herdr RemoteArtifact helper path is unreadable"
  [[ "$expected_relative" == "bin/OuroWorkbenchRemote" ]] \
    || fail "Herdr RemoteArtifact helper path is unexpected: $expected_relative"
  expected_sha256="$(remote_manifest_value "$manifest" files.0.sha256)" \
    || fail "Herdr RemoteArtifact helper digest is unreadable"
  observed_sha256="$(/usr/bin/shasum -a 256 "$helper" | /usr/bin/awk '{print $1}')"
  [[ "$expected_sha256" == "$observed_sha256" ]] \
    || fail "Herdr RemoteArtifact helper digest does not match its signed executable"
}

refresh_remote_manifest_digest() {
  local manifest="$1"
  local helper="$2"
  local sha256

  sha256="$(/usr/bin/shasum -a 256 "$helper" | /usr/bin/awk '{print $1}')"
  /usr/bin/plutil -replace files.0.sha256 -string "$sha256" "$manifest" \
    || fail "could not refresh the Herdr RemoteArtifact helper digest"
  chmod 600 "$manifest"
  verify_remote_manifest_digest "$manifest" "$helper"
}

sign_herdr_remote_helper() {
  local remote_root="$APP_PATH/$REMOTE_ARTIFACT_RELATIVE"
  local manifest="$remote_root/manifest.json"
  local helper="$remote_root/bin/OuroWorkbenchRemote"

  printf '==> Developer ID signing Herdr RemoteArtifact helper %s\n' "$helper"
  [[ -d "$remote_root" ]] || fail "Herdr RemoteArtifact is missing: $remote_root"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$helper"
  refresh_remote_manifest_digest "$manifest" "$helper"
  codesign --verify --strict --verbose=2 "$helper"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 && -n "$2" ]] || { usage; exit 64; }
      APP_PATH="$2"
      shift 2
      ;;
    --app-name)
      [[ $# -ge 2 && -n "$2" ]] || { usage; exit 64; }
      APP_NAME="$2"
      shift 2
      ;;
    --selftest)
      "$0" --help >/dev/null
      status=0
      "$0" --app /definitely/missing.app >/tmp/ouro-workbench-sign-notarize-selftest.out 2>/tmp/ouro-workbench-sign-notarize-selftest.err || status=$?
      [[ "$status" -ne 0 ]] || fail "selftest expected missing app to fail"
      TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ouro-workbench-sign-notarize-selftest.XXXXXX")"
      fixture_root="$TMP_ROOT/$REMOTE_ARTIFACT_RELATIVE"
      fixture_manifest="$fixture_root/manifest.json"
      fixture_helper="$fixture_root/bin/OuroWorkbenchRemote"
      mkdir -p "$fixture_root/bin"
      printf 'fixture-helper' > "$fixture_helper"
      chmod 755 "$fixture_helper"
      printf '{"files":[{"relativePath":"bin/OuroWorkbenchRemote","sha256":"stale"}]}\n' > "$fixture_manifest"
      chmod 600 "$fixture_manifest"
      refresh_remote_manifest_digest "$fixture_manifest" "$fixture_helper"
      verify_remote_manifest_digest "$fixture_manifest" "$fixture_helper"
      printf 'sign-notarize selftest ok\n'
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

[[ -n "$APP_PATH" ]] || { usage; exit 64; }
[[ -d "$APP_PATH" ]] || fail "app bundle not found: $APP_PATH"
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
APP_NAME="${APP_NAME:-$(basename "$APP_PATH" .app)}"

command -v codesign >/dev/null 2>&1 || fail "codesign is required"
command -v xcrun >/dev/null 2>&1 || fail "xcrun is required"
xcrun notarytool --help >/dev/null 2>&1 || fail "xcrun notarytool is required"
xcrun -f stapler >/dev/null 2>&1 || fail "xcrun stapler is required"

[[ -n "$IDENTITY" ]] || fail "Developer ID signing requires OURO_CODESIGN_IDENTITY or DEVELOPER_ID_APPLICATION"
security find-identity -v -p codesigning | grep -Fq "$IDENTITY" \
  || fail "configured signing identity was not found in this keychain"

notary_args=()
if [[ -n "$NOTARY_PROFILE" ]]; then
  notary_args=(--keychain-profile "$NOTARY_PROFILE")
elif have_all APP_STORE_CONNECT_API_KEY_ID APP_STORE_CONNECT_API_ISSUER_ID APP_STORE_CONNECT_API_KEY_PATH; then
  [[ -f "$APP_STORE_CONNECT_API_KEY_PATH" ]] || fail "APP_STORE_CONNECT_API_KEY_PATH does not point to a file"
  notary_args=(
    --key "$APP_STORE_CONNECT_API_KEY_PATH"
    --key-id "$APP_STORE_CONNECT_API_KEY_ID"
    --issuer "$APP_STORE_CONNECT_API_ISSUER_ID"
  )
elif have_all APPLE_ID APPLE_TEAM_ID APPLE_APP_SPECIFIC_PASSWORD; then
  notary_args=(
    --apple-id "$APPLE_ID"
    --team-id "$APPLE_TEAM_ID"
    --password "$APPLE_APP_SPECIFIC_PASSWORD"
  )
else
  fail "notarization requires OURO_NOTARY_PROFILE, App Store Connect API key env, or Apple ID app-specific password env"
fi

sign_herdr_remote_helper

printf '==> Developer ID signing %s\n' "$APP_PATH"
codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
verify_remote_manifest_digest \
  "$APP_PATH/$REMOTE_ARTIFACT_RELATIVE/manifest.json" \
  "$APP_PATH/$REMOTE_ARTIFACT_RELATIVE/bin/OuroWorkbenchRemote"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ouro-workbench-notary.XXXXXX")"
notary_zip="$TMP_ROOT/${APP_NAME}-notary.zip"
printf '==> Creating notarization upload %s\n' "$notary_zip"
ditto -c -k --keepParent "$APP_PATH" "$notary_zip"

printf '==> Submitting to Apple notary service\n'
submission_json="$TMP_ROOT/notary-submission.json"
if ! xcrun notarytool submit "$notary_zip" "${notary_args[@]}" --wait --output-format json > "$submission_json"; then
  /bin/cat "$submission_json" >&2
  fail "Apple notary submission command failed"
fi
/bin/cat "$submission_json"
submission_id="$(/usr/bin/plutil -extract id raw -o - "$submission_json" 2>/dev/null)" \
  || fail "Apple notary response did not contain a submission id"
submission_status="$(/usr/bin/plutil -extract status raw -o - "$submission_json" 2>/dev/null)" \
  || fail "Apple notary response did not contain a status"
if [[ "$submission_status" != "Accepted" ]]; then
  printf '==> Fetching Apple notary rejection log for %s\n' "$submission_id" >&2
  xcrun notarytool log "$submission_id" "${notary_args[@]}" >&2 \
    || printf 'Signing/notarization warning: Apple notary rejection log was unavailable\n' >&2
  fail "Apple notary submission $submission_id finished with status $submission_status"
fi

printf '==> Stapling notarization ticket\n'
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

if command -v spctl >/dev/null 2>&1; then
  spctl --assess --type execute --verbose=2 "$APP_PATH"
fi

printf 'developer-id notarization ok: %s\n' "$APP_PATH"
