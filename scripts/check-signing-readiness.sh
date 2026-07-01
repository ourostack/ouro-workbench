#!/usr/bin/env bash
#
# Verifies that this host can perform Developer ID signing/notarization when a
# release explicitly opts into it. Defaults to a non-secret tooling check so CI
# can run it before certificates are available.
set -euo pipefail

require_notarization="${OURO_REQUIRE_NOTARIZATION:-}"
validate_credentials="${OURO_VALIDATE_NOTARY_CREDENTIALS:-}"

fail() {
  printf 'Signing readiness failed: %s\n' "$*" >&2
  exit 1
}

truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

have_all() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || return 1
  done
}

command -v codesign >/dev/null 2>&1 || fail "codesign is required"
command -v xcrun >/dev/null 2>&1 || fail "xcrun is required"
xcrun notarytool --help >/dev/null 2>&1 || fail "xcrun notarytool is required"
xcrun -f stapler >/dev/null 2>&1 || fail "xcrun stapler is required"

if [[ "${1:-}" == "--selftest" ]]; then
  OURO_REQUIRE_NOTARIZATION=1 OURO_CODESIGN_IDENTITY= DEVELOPER_ID_APPLICATION= "$0" >/tmp/ouro-workbench-signing-readiness-selftest.out 2>/tmp/ouro-workbench-signing-readiness-selftest.err && {
    fail "selftest expected required notarization without identity to fail"
  }
  grep -F "requires OURO_CODESIGN_IDENTITY" /tmp/ouro-workbench-signing-readiness-selftest.err >/dev/null \
    || fail "selftest did not exercise missing identity failure"
  printf 'signing readiness selftest ok\n'
  exit 0
fi

identity="${OURO_CODESIGN_IDENTITY:-${DEVELOPER_ID_APPLICATION:-}}"
if [[ -n "$identity" ]]; then
  security find-identity -v -p codesigning | grep -Fq "$identity" \
    || fail "configured signing identity was not found in this keychain"
  printf 'signing identity: configured\n'
elif truthy "$require_notarization"; then
  fail "OURO_REQUIRE_NOTARIZATION=1 requires OURO_CODESIGN_IDENTITY or DEVELOPER_ID_APPLICATION"
else
  printf 'signing identity: not configured (allowed for unsigned/ad-hoc checks)\n'
fi

auth_mode=""
if [[ -n "${OURO_NOTARY_PROFILE:-}" ]]; then
  auth_mode="keychain-profile"
elif have_all APP_STORE_CONNECT_API_KEY_ID APP_STORE_CONNECT_API_ISSUER_ID APP_STORE_CONNECT_API_KEY_PATH; then
  [[ -f "$APP_STORE_CONNECT_API_KEY_PATH" ]] || fail "APP_STORE_CONNECT_API_KEY_PATH does not point to a file"
  auth_mode="app-store-connect-api-key"
elif have_all APPLE_ID APPLE_TEAM_ID APPLE_APP_SPECIFIC_PASSWORD; then
  auth_mode="apple-id-password"
fi

if [[ -z "$auth_mode" ]]; then
  if truthy "$require_notarization"; then
    fail "notarization is required but no supported notary credentials are configured"
  fi
  printf 'notarization credentials: not configured (allowed until release signing is required)\n'
  printf 'signing readiness ok\n'
  exit 0
fi

printf 'notarization credentials: %s configured\n' "$auth_mode"

if truthy "$validate_credentials"; then
  case "$auth_mode" in
    keychain-profile)
      xcrun notarytool history --keychain-profile "$OURO_NOTARY_PROFILE" >/dev/null
      ;;
    app-store-connect-api-key)
      xcrun notarytool history \
        --key "$APP_STORE_CONNECT_API_KEY_PATH" \
        --key-id "$APP_STORE_CONNECT_API_KEY_ID" \
        --issuer "$APP_STORE_CONNECT_API_ISSUER_ID" >/dev/null
      ;;
    apple-id-password)
      xcrun notarytool history \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" >/dev/null
      ;;
  esac
  printf 'notarization credentials: live validation ok\n'
fi

printf 'signing readiness ok\n'
