#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$("$ROOT_DIR/scripts/read-workbench-release.sh")"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ouro-workbench-web-installer.XXXXXX")"
FAKE_BIN="$TEMP_ROOT/bin"
FAKE_LOG="$TEMP_ROOT/curl.log"
REAL_CODESIGN="$(command -v codesign)"

cleanup() {
  rm -rf "$TEMP_ROOT"
}

trap cleanup EXIT

latest_manifest="$(find "$ARTIFACTS_DIR" -name "$WORKBENCH_ARTIFACT_NAME_PREFIX${VERSION}-*.manifest.json" -type f -print | sort | tail -n 1)"
if [[ -z "$latest_manifest" ]]; then
  printf 'Web installer selftest failed: no manifest found for version %s in %s\n' "$VERSION" "$ARTIFACTS_DIR" >&2
  exit 1
fi
archive_name="$(plutil -extract archive raw -o - "$latest_manifest")"
archive_path="$(dirname "$latest_manifest")/$archive_name"
[[ -f "$archive_path" ]] || {
  printf 'Web installer selftest failed: archive missing for %s\n' "$latest_manifest" >&2
  exit 1
}

build="$(plutil -extract build raw -o - "$latest_manifest")"
sha="$(git -C "$ROOT_DIR" rev-parse HEAD)"
short_sha="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
clean_archive_name="$WORKBENCH_ARTIFACT_NAME_PREFIX${VERSION}-build.${build}-${short_sha}.zip"
clean_manifest_name="$WORKBENCH_ARTIFACT_NAME_PREFIX${VERSION}-build.${build}-${short_sha}.manifest.json"
clean_asset_dir="$TEMP_ROOT/clean-assets"
mkdir -p "$clean_asset_dir"
cp "$archive_path" "$clean_asset_dir/$clean_archive_name"
cp "$latest_manifest" "$clean_asset_dir/$clean_manifest_name"
plutil -replace archive -string "$clean_archive_name" "$clean_asset_dir/$clean_manifest_name"
plutil -replace gitSha -string "$sha" "$clean_asset_dir/$clean_manifest_name"
plutil -replace gitDirty -bool false "$clean_asset_dir/$clean_manifest_name"
manifest_version="$(plutil -extract version raw -o - "$clean_asset_dir/$clean_manifest_name")"

write_release_json() {
  local output="$1"
  local archive="$2"
  local manifest="$3"
  cat > "$output" <<JSON
[
  {
    "assets": [
      {"browser_download_url": "https://example.invalid/$archive"},
      {"browser_download_url": "https://example.invalid/$manifest"}
    ]
  }
]
JSON
}

write_extra_release_json() {
  local output="$1"
  cat > "$output" <<JSON
[
  {
    "assets": [
      {"browser_download_url": "https://example.invalid/TotallyUnrelated.zip"},
      {"browser_download_url": "https://example.invalid/TotallyUnrelated.manifest.json"},
      {"browser_download_url": "https://example.invalid/$clean_archive_name"},
      {"browser_download_url": "https://example.invalid/$clean_manifest_name"}
    ]
  }
]
JSON
}

rewrite_manifest_for_archive() {
  local source_manifest="$1"
  local output_manifest="$2"
  local archive="$3"
  local archive_file="$4"
  local sha256
  local bytes

  cp "$source_manifest" "$output_manifest"
  sha256="$(shasum -a 256 "$archive_file" | awk '{print $1}')"
  bytes="$(stat -f %z "$archive_file")"
  plutil -replace archive -string "$archive" "$output_manifest"
  plutil -replace sha256 -string "$sha256" "$output_manifest"
  plutil -replace bytes -integer "$bytes" "$output_manifest"
  plutil -replace gitSha -string "$sha" "$output_manifest"
  plutil -replace gitDirty -bool false "$output_manifest"
}

release_json="$TEMP_ROOT/release.json"
write_release_json "$release_json" "$clean_archive_name" "$clean_manifest_name"

mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

: "${FAKE_RELEASE_JSON:?}"
: "${FAKE_ARCHIVE_PATH:?}"
: "${FAKE_MANIFEST_PATH:?}"
: "${FAKE_CURL_LOG:?}"

output=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

printf '%s\n' "$url" >> "$FAKE_CURL_LOG"

emit_file() {
  local source="$1"
  if [[ -n "$output" ]]; then
    cp "$source" "$output"
  else
    cat "$source"
  fi
}

case "$url" in
  https://api.github.com/repos/*/releases?per_page=1)
    emit_file "$FAKE_RELEASE_JSON"
    ;;
  https://example.invalid/*.zip)
    emit_file "$FAKE_ARCHIVE_PATH"
    ;;
  https://example.invalid/*.manifest.json)
    emit_file "$FAKE_MANIFEST_PATH"
    ;;
  *)
    printf 'unexpected fake curl URL: %s\n' "$url" >&2
    exit 2
    ;;
esac
SH
chmod +x "$FAKE_BIN/curl"

cat > "$FAKE_BIN/codesign" <<SH
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "\${FAKE_CODESIGN_FAIL_PATH:-}" ]]; then
  for arg in "\$@"; do
    if [[ "\$arg" == "\$FAKE_CODESIGN_FAIL_PATH" ]]; then
      if [[ -n "\${FAKE_CODESIGN_HIT_LOG:-}" ]]; then
        printf '%s\\n' "\$arg" >> "\$FAKE_CODESIGN_HIT_LOG"
      fi
      printf 'simulated final destination codesign failure\\n' >&2
      exit 42
    fi
  done
fi

exec "$REAL_CODESIGN" "\$@"
SH
chmod +x "$FAKE_BIN/codesign"

success_install_dir="$TEMP_ROOT/success/Applications"
mkdir -p "$success_install_dir"
PATH="$FAKE_BIN:$PATH" \
  FAKE_RELEASE_JSON="$release_json" \
  FAKE_ARCHIVE_PATH="$clean_asset_dir/$clean_archive_name" \
  FAKE_MANIFEST_PATH="$clean_asset_dir/$clean_manifest_name" \
  FAKE_CURL_LOG="$FAKE_LOG" \
  OURO_WB_INSTALL_DIR="$success_install_dir" \
  OURO_WB_NO_OPEN=1 \
  "$ROOT_DIR/web/workbench-install.sh" >/dev/null

"$ROOT_DIR/scripts/verify-app-bundle.sh" \
  "$success_install_dir/$WORKBENCH_APP_NAME.app" \
  --expected-version "$manifest_version" >/dev/null

extra_release_json="$TEMP_ROOT/extra-assets-release.json"
write_extra_release_json "$extra_release_json"
set +e
PATH="$FAKE_BIN:$PATH" \
  FAKE_RELEASE_JSON="$extra_release_json" \
  FAKE_ARCHIVE_PATH="$clean_asset_dir/$clean_archive_name" \
  FAKE_MANIFEST_PATH="$clean_asset_dir/$clean_manifest_name" \
  FAKE_CURL_LOG="$FAKE_LOG" \
  OURO_WB_INSTALL_DIR="$TEMP_ROOT/extra/Applications" \
  OURO_WB_NO_OPEN=1 \
  "$ROOT_DIR/web/workbench-install.sh" >"$TEMP_ROOT/extra.out" 2>"$TEMP_ROOT/extra.err"
extra_status=$?
set -e
if [[ "$extra_status" -eq 0 ]]; then
  printf 'Web installer selftest failed: extra release assets unexpectedly installed\n' >&2
  exit 1
fi
grep -Fq 'expected exactly one public .zip asset' "$TEMP_ROOT/extra.err" || {
  printf 'Web installer selftest failed: extra-asset diagnostic missing, got:\n' >&2
  cat "$TEMP_ROOT/extra.err" >&2
  exit 1
}

bad_asset_dir="$TEMP_ROOT/bad-assets"
bad_app_dir="$TEMP_ROOT/bad-app"
mkdir -p "$bad_asset_dir" "$bad_app_dir"
ditto "$success_install_dir/$WORKBENCH_APP_NAME.app" "$bad_app_dir/$WORKBENCH_APP_NAME.app"
rm -f "$bad_app_dir/$WORKBENCH_APP_NAME.app/Contents/MacOS/$WORKBENCH_MCP_EXECUTABLE"
"$REAL_CODESIGN" --force --deep --sign - "$bad_app_dir/$WORKBENCH_APP_NAME.app" >/dev/null
ditto -c -k --keepParent "$bad_app_dir/$WORKBENCH_APP_NAME.app" "$bad_asset_dir/$clean_archive_name"
rewrite_manifest_for_archive \
  "$clean_asset_dir/$clean_manifest_name" \
  "$bad_asset_dir/$clean_manifest_name" \
  "$clean_archive_name" \
  "$bad_asset_dir/$clean_archive_name"
bad_release_json="$TEMP_ROOT/bad-release.json"
write_release_json "$bad_release_json" "$clean_archive_name" "$clean_manifest_name"

set +e
PATH="$FAKE_BIN:$PATH" \
  FAKE_RELEASE_JSON="$bad_release_json" \
  FAKE_ARCHIVE_PATH="$bad_asset_dir/$clean_archive_name" \
  FAKE_MANIFEST_PATH="$bad_asset_dir/$clean_manifest_name" \
  FAKE_CURL_LOG="$FAKE_LOG" \
  OURO_WB_INSTALL_DIR="$TEMP_ROOT/bad/Applications" \
  OURO_WB_NO_OPEN=1 \
  "$ROOT_DIR/web/workbench-install.sh" >"$TEMP_ROOT/bad.out" 2>"$TEMP_ROOT/bad.err"
bad_status=$?
set -e
if [[ "$bad_status" -eq 0 ]]; then
  printf 'Web installer selftest failed: incomplete bundle unexpectedly installed\n' >&2
  exit 1
fi
grep -Fq 'MCP executable is missing or not executable' "$TEMP_ROOT/bad.err" || {
  printf 'Web installer selftest failed: expected MCP diagnostic, got:\n' >&2
  cat "$TEMP_ROOT/bad.err" >&2
  exit 1
}

rollback_install_dir="$TEMP_ROOT/rollback/Applications"
mkdir -p "$rollback_install_dir"
ditto "$success_install_dir/$WORKBENCH_APP_NAME.app" "$rollback_install_dir/$WORKBENCH_APP_NAME.app"
marker="$rollback_install_dir/$WORKBENCH_APP_NAME.app/Contents/Resources/web-installer-rollback-marker"
printf 'previous install survived\n' > "$marker"
"$REAL_CODESIGN" --force --deep --sign - "$rollback_install_dir/$WORKBENCH_APP_NAME.app" >/dev/null

set +e
codesign_hit_log="$TEMP_ROOT/codesign-hit.log"
PATH="$FAKE_BIN:$PATH" \
  FAKE_RELEASE_JSON="$release_json" \
  FAKE_ARCHIVE_PATH="$clean_asset_dir/$clean_archive_name" \
  FAKE_MANIFEST_PATH="$clean_asset_dir/$clean_manifest_name" \
  FAKE_CURL_LOG="$FAKE_LOG" \
  FAKE_CODESIGN_FAIL_PATH="$rollback_install_dir/$WORKBENCH_APP_NAME.app" \
  FAKE_CODESIGN_HIT_LOG="$codesign_hit_log" \
  OURO_WB_INSTALL_DIR="$rollback_install_dir" \
  OURO_WB_NO_OPEN=1 \
  "$ROOT_DIR/web/workbench-install.sh" >"$TEMP_ROOT/rollback.out" 2>"$TEMP_ROOT/rollback.err"
rollback_status=$?
set -e

if [[ "$rollback_status" -eq 0 ]]; then
  printf 'Web installer selftest failed: post-replacement failure unexpectedly installed\n' >&2
  exit 1
fi
if [[ ! -f "$marker" ]]; then
  printf 'Web installer selftest failed: previous app marker was not restored after post-replacement failure\n' >&2
  exit 1
fi
grep -Fq "$rollback_install_dir/$WORKBENCH_APP_NAME.app" "$codesign_hit_log" || {
  printf 'Web installer selftest failed: fake codesign did not fail the final destination path\n' >&2
  exit 1
}
grep -Fq 'app bundle code signature does not verify' "$TEMP_ROOT/rollback.err" || {
  printf 'Web installer selftest failed: expected post-replacement failure diagnostic, got:\n' >&2
  cat "$TEMP_ROOT/rollback.err" >&2
  exit 1
}
"$ROOT_DIR/scripts/verify-app-bundle.sh" \
  "$rollback_install_dir/$WORKBENCH_APP_NAME.app" \
  --expected-version "$manifest_version" >/dev/null

grep -Fq 'verify_app_bundle "$staged_app"' "$ROOT_DIR/web/workbench-install.sh" || {
  printf 'Web installer must verify the staged app before replacement.\n' >&2
  exit 1
}
grep -Fq 'select_release_assets' "$ROOT_DIR/web/workbench-install.sh" || {
  printf 'Web installer must select canonical release assets explicitly.\n' >&2
  exit 1
}
grep -Fq 'restore_previous_install' "$ROOT_DIR/web/workbench-install.sh" || {
  printf 'Web installer must keep rollback cleanup logic.\n' >&2
  exit 1
}
grep -Fq 'WEB_INSTALLER_URL' "$ROOT_DIR/scripts/verify-published-release.sh" || {
  printf 'Published release verifier must fetch the hosted public web installer.\n' >&2
  exit 1
}

printf 'Web installer selftest passed\n'
