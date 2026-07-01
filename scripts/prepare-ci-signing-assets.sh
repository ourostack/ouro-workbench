#!/usr/bin/env bash
#
# Prepares GitHub-hosted macOS runners for Developer ID signing by importing a
# base64-encoded certificate into a temporary keychain and materializing a
# base64-encoded App Store Connect API key file. No-ops unless signing is
# explicitly required.
set -euo pipefail

require="${OURO_REQUIRE_NOTARIZATION:-}"
mode="${OURO_RELEASE_SIGNING_MODE:-}"

truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

if [[ "$mode" != "developer-id" ]] && ! truthy "$require"; then
  echo "ci signing assets: not required"
  exit 0
fi

fail() {
  printf 'CI signing asset setup failed: %s\n' "$*" >&2
  exit 1
}

env_out="${GITHUB_ENV:-}"
[[ -n "$env_out" ]] || fail "GITHUB_ENV is required to share CI signing assets with later steps"
[[ -n "${APPLE_DEVELOPER_ID_CERTIFICATE_BASE64:-}" ]] || fail "APPLE_DEVELOPER_ID_CERTIFICATE_BASE64 is required for CI Developer ID signing"
[[ -n "${APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD:-}" ]] || fail "APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD is required for CI Developer ID signing"

tmp_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/ouro-workbench-ci-signing.XXXXXX")"
cert_path="$tmp_root/developer-id.p12"
keychain_path="$tmp_root/ouro-workbench-signing.keychain-db"
keychain_password="$(uuidgen)"

printf '%s' "$APPLE_DEVELOPER_ID_CERTIFICATE_BASE64" | base64 --decode > "$cert_path"
security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$cert_path" -k "$keychain_path" -P "$APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain_path" >/dev/null
security list-keychains -d user -s "$keychain_path" $(security list-keychains -d user | sed 's/[ "]*//g')

{
  echo "OURO_SIGNING_KEYCHAIN_PATH=$keychain_path"
  if [[ -n "${APPLE_DEVELOPER_ID_CERTIFICATE_IDENTITY:-}" && -z "${OURO_CODESIGN_IDENTITY:-}" ]]; then
    echo "OURO_CODESIGN_IDENTITY=$APPLE_DEVELOPER_ID_CERTIFICATE_IDENTITY"
  fi
} >> "$env_out"

if [[ -n "${APP_STORE_CONNECT_API_KEY_BASE64:-}" ]]; then
  key_dir="$tmp_root/private_keys"
  mkdir -p "$key_dir"
  key_path="$key_dir/AuthKey_${APP_STORE_CONNECT_API_KEY_ID:-UNKNOWN}.p8"
  printf '%s' "$APP_STORE_CONNECT_API_KEY_BASE64" | base64 --decode > "$key_path"
  chmod 600 "$key_path"
  echo "APP_STORE_CONNECT_API_KEY_PATH=$key_path" >> "$env_out"
elif [[ -n "${APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64:-}" ]]; then
  key_dir="$tmp_root/private_keys"
  mkdir -p "$key_dir"
  key_path="$key_dir/AuthKey_${APP_STORE_CONNECT_API_KEY_ID:-UNKNOWN}.p8"
  printf '%s' "$APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64" | base64 --decode > "$key_path"
  chmod 600 "$key_path"
  echo "APP_STORE_CONNECT_API_KEY_PATH=$key_path" >> "$env_out"
fi

echo "ci signing assets: prepared"
