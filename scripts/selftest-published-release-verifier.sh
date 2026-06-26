#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$("$ROOT_DIR/scripts/read-workbench-release.sh")"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ouro-workbench-published-selftest.XXXXXX")"

cleanup() {
  rm -rf "$TEMP_ROOT"
}

trap cleanup EXIT

latest_manifest="$(find "$ARTIFACTS_DIR" -name "$WORKBENCH_ARTIFACT_NAME_PREFIX*.manifest.json" -type f -print | sort | tail -n 1)"
if [[ -z "$latest_manifest" ]]; then
  printf 'Published release verifier selftest failed: no manifest found in %s\n' "$ARTIFACTS_DIR" >&2
  exit 1
fi
archive_name="$(plutil -extract archive raw -o - "$latest_manifest")"
latest_archive="$(dirname "$latest_manifest")/$archive_name"
if [[ ! -f "$latest_archive" ]]; then
  printf 'Published release verifier selftest failed: archive missing for %s\n' "$latest_manifest" >&2
  exit 1
fi

tag="v$WORKBENCH_VERSION"
sha="$(git -C "$ROOT_DIR" rev-parse HEAD)"
short_sha="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
build="$(plutil -extract build raw -o - "$latest_manifest")"
clean_asset_dir="$TEMP_ROOT/clean-assets"
clean_archive_name="$WORKBENCH_ARTIFACT_NAME_PREFIX${WORKBENCH_VERSION}-build.${build}-${short_sha}.zip"
clean_manifest_name="$WORKBENCH_ARTIFACT_NAME_PREFIX${WORKBENCH_VERSION}-build.${build}-${short_sha}.manifest.json"
hosted_installer_url="https://example.invalid/workbench-install.sh"
default_web_installer_url="https://raw.githubusercontent.com/ourostack/ouro-workbench/$sha/web/workbench-install.sh"
fake_bin="$TEMP_ROOT/bin"
fake_curl_log="$TEMP_ROOT/curl.log"
stale_web_installer="$TEMP_ROOT/stale-workbench-install.sh"
mkdir -p "$clean_asset_dir"
cp "$latest_archive" "$clean_asset_dir/$clean_archive_name"
cp "$latest_manifest" "$clean_asset_dir/$clean_manifest_name"
plutil -replace archive -string "$clean_archive_name" "$clean_asset_dir/$clean_manifest_name"
plutil -replace gitSha -string "$sha" "$clean_asset_dir/$clean_manifest_name"
plutil -replace gitDirty -bool false "$clean_asset_dir/$clean_manifest_name"
cp "$ROOT_DIR/web/workbench-install.sh" "$stale_web_installer"
printf '\n# stale deployment sentinel\n' >> "$stale_web_installer"
release_json="$TEMP_ROOT/release.json"
cat > "$release_json" <<JSON
[
  {
    "assets": [
      {"browser_download_url": "https://example.invalid/$clean_archive_name"},
      {"browser_download_url": "https://example.invalid/$clean_manifest_name"}
    ]
  }
]
JSON
fake_gh="$TEMP_ROOT/gh"
cat > "$fake_gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

: "${FAKE_TAG:?}"
: "${FAKE_SHA:?}"
: "${FAKE_ASSET_DIR:?}"

if [[ "$#" -lt 2 || "$1" != "release" ]]; then
  printf 'fake gh only supports release commands\n' >&2
  exit 99
fi
command="$2"
shift 2

case "$command" in
  view)
    tag="${1:-}"
    shift || true
    [[ "$tag" == "$FAKE_TAG" ]] || exit 1
    jq_expr=""
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        --repo|--json)
          shift 2
          ;;
        --jq)
          jq_expr="${2:-}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    case "$jq_expr" in
      .tagName)
        printf '%s\n' "$FAKE_TAG"
        ;;
      .isDraft)
        printf 'false\n'
        ;;
      .isPrerelease)
        printf '%s\n' "${FAKE_PRERELEASE:-true}"
        ;;
      .targetCommitish)
        printf '%s\n' "${FAKE_TARGET:-$FAKE_SHA}"
        ;;
      '.assets[].name')
        find "$FAKE_ASSET_DIR" -maxdepth 1 -type f -print | sort | while IFS= read -r asset; do
          name="$(basename "$asset")"
          if [[ "${FAKE_ASSET_MODE:-}" == "missing-manifest" && "$name" == *.manifest.json ]]; then
            continue
          fi
          printf '%s\n' "$name"
        done
        ;;
      *)
        printf 'unsupported fake gh release view jq: %s\n' "$jq_expr" >&2
        exit 99
        ;;
    esac
    ;;
  list)
    jq_expr=""
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        --repo|--limit|--json)
          shift 2
          ;;
        --exclude-drafts)
          shift
          ;;
        --jq)
          jq_expr="${2:-}"
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    [[ "$jq_expr" == '.[0].tagName' ]] || {
      printf 'unsupported fake gh release list jq: %s\n' "$jq_expr" >&2
      exit 99
    }
    printf '%s\n' "${FAKE_LATEST_TAG:-$FAKE_TAG}"
    ;;
  download)
    tag="${1:-}"
    shift || true
    [[ "$tag" == "$FAKE_TAG" ]] || exit 1
    patterns=()
    destination=""
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        --repo)
          shift 2
        ;;
      --pattern)
        patterns+=("${2:-}")
        shift 2
        ;;
        --dir)
          destination="${2:-}"
          shift 2
          ;;
        *)
          shift
        ;;
    esac
    done
    [[ "${#patterns[@]}" -gt 0 && -n "$destination" ]] || exit 64
    mkdir -p "$destination"
    for pattern in "${patterns[@]}"; do
      matched="false"
      for asset in "$FAKE_ASSET_DIR"/$pattern; do
        [[ -e "$asset" ]] || continue
        cp "$asset" "$destination/"
        matched="true"
      done
      [[ "$matched" == "true" ]] || {
        printf 'fake gh download found no assets for pattern: %s\n' "$pattern" >&2
        exit 1
      }
    done
    ;;
  *)
    printf 'unsupported fake gh release command: %s\n' "$command" >&2
    exit 99
    ;;
esac
SH
chmod +x "$fake_gh"
mkdir -p "$fake_bin"
ln -sf "$fake_gh" "$fake_bin/gh"

cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

: "${FAKE_RELEASE_JSON:?}"
: "${FAKE_ARCHIVE_PATH:?}"
: "${FAKE_MANIFEST_PATH:?}"
: "${FAKE_WEB_INSTALLER_PATH:?}"
: "${FAKE_WEB_INSTALLER_URL:?}"
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
  "$FAKE_WEB_INSTALLER_URL")
    emit_file "$FAKE_WEB_INSTALLER_PATH"
    ;;
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
chmod +x "$fake_bin/curl"

PATH="$fake_bin:$PATH" \
  GH_BIN="$fake_gh" \
  FAKE_TAG="$tag" \
  FAKE_SHA="$sha" \
  FAKE_ASSET_DIR="$clean_asset_dir" \
  FAKE_RELEASE_JSON="$release_json" \
  FAKE_ARCHIVE_PATH="$clean_asset_dir/$clean_archive_name" \
  FAKE_MANIFEST_PATH="$clean_asset_dir/$clean_manifest_name" \
  FAKE_WEB_INSTALLER_PATH="$ROOT_DIR/web/workbench-install.sh" \
  FAKE_WEB_INSTALLER_URL="$default_web_installer_url" \
  FAKE_CURL_LOG="$fake_curl_log" \
  OURO_WB_WEB_INSTALLER_ATTEMPTS=1 \
  OURO_WB_WEB_INSTALLER_RETRY_SECONDS=0 \
  "$ROOT_DIR/scripts/verify-published-release.sh" \
    --repo ourostack/ouro-workbench \
    --tag "$tag" \
    --version "$WORKBENCH_VERSION" \
    --sha "$sha" \
    --prerelease true >/dev/null

set +e
PATH="$fake_bin:$PATH" \
  GH_BIN="$fake_gh" \
  FAKE_TAG="$tag" \
  FAKE_SHA="$sha" \
  FAKE_ASSET_DIR="$clean_asset_dir" \
  FAKE_RELEASE_JSON="$release_json" \
  FAKE_ARCHIVE_PATH="$clean_asset_dir/$clean_archive_name" \
  FAKE_MANIFEST_PATH="$clean_asset_dir/$clean_manifest_name" \
  FAKE_WEB_INSTALLER_PATH="$stale_web_installer" \
  FAKE_WEB_INSTALLER_URL="$hosted_installer_url" \
  FAKE_CURL_LOG="$fake_curl_log" \
  OURO_WB_WEB_INSTALLER_URL="$hosted_installer_url" \
  OURO_WB_WEB_INSTALLER_ATTEMPTS=1 \
  OURO_WB_WEB_INSTALLER_RETRY_SECONDS=0 \
  "$ROOT_DIR/scripts/verify-published-release.sh" \
    --repo ourostack/ouro-workbench \
    --tag "$tag" \
    --version "$WORKBENCH_VERSION" \
    --sha "$sha" \
    --prerelease true >/dev/null 2>"$TEMP_ROOT/stale-hosted-installer.err"
stale_hosted_status=$?
set -e
if [[ "$stale_hosted_status" -eq 0 ]]; then
  printf 'Published release verifier selftest failed: stale hosted installer unexpectedly passed\n' >&2
  exit 1
fi
grep -Fq 'does not match' "$TEMP_ROOT/stale-hosted-installer.err" || {
  printf 'Published release verifier selftest failed: stale hosted installer diagnostic missing\n' >&2
  cat "$TEMP_ROOT/stale-hosted-installer.err" >&2
  exit 1
}

set +e
GH_BIN="$fake_gh" \
  FAKE_TAG="$tag" \
  FAKE_SHA="$sha" \
  FAKE_TARGET="0000000000000000000000000000000000000000" \
  FAKE_ASSET_DIR="$clean_asset_dir" \
  "$ROOT_DIR/scripts/verify-published-release.sh" \
    --repo ourostack/ouro-workbench \
    --tag "$tag" \
    --version "$WORKBENCH_VERSION" \
    --sha "$sha" \
    --prerelease true \
    --skip-install >/dev/null 2>"$TEMP_ROOT/bad-target.err"
bad_target_status=$?
set -e
if [[ "$bad_target_status" -eq 0 ]]; then
  printf 'Published release verifier selftest failed: target mismatch unexpectedly passed\n' >&2
  exit 1
fi
grep -Fq 'targets 0000000000000000000000000000000000000000' "$TEMP_ROOT/bad-target.err" || {
  printf 'Published release verifier selftest failed: target mismatch diagnostic missing\n' >&2
  cat "$TEMP_ROOT/bad-target.err" >&2
  exit 1
}

set +e
GH_BIN="$fake_gh" \
  FAKE_TAG="$tag" \
  FAKE_SHA="$sha" \
  FAKE_ASSET_MODE="missing-manifest" \
  FAKE_ASSET_DIR="$clean_asset_dir" \
  "$ROOT_DIR/scripts/verify-published-release.sh" \
    --repo ourostack/ouro-workbench \
    --tag "$tag" \
    --version "$WORKBENCH_VERSION" \
    --sha "$sha" \
    --prerelease true \
    --skip-install >/dev/null 2>"$TEMP_ROOT/missing-manifest.err"
missing_manifest_status=$?
set -e
if [[ "$missing_manifest_status" -eq 0 ]]; then
  printf 'Published release verifier selftest failed: missing manifest unexpectedly passed\n' >&2
  exit 1
fi
grep -Fq 'expected exactly one' "$TEMP_ROOT/missing-manifest.err" || {
  printf 'Published release verifier selftest failed: missing manifest diagnostic missing\n' >&2
  cat "$TEMP_ROOT/missing-manifest.err" >&2
  exit 1
}

extra_assets_dir="$TEMP_ROOT/extra-assets"
mkdir -p "$extra_assets_dir"
cp "$clean_asset_dir/$clean_archive_name" "$extra_assets_dir/$clean_archive_name"
cp "$clean_asset_dir/$clean_manifest_name" "$extra_assets_dir/$clean_manifest_name"
cp "$clean_asset_dir/$clean_archive_name" "$extra_assets_dir/TotallyUnrelated.zip"
cp "$clean_asset_dir/$clean_manifest_name" "$extra_assets_dir/TotallyUnrelated.manifest.json"
set +e
GH_BIN="$fake_gh" \
  FAKE_TAG="$tag" \
  FAKE_SHA="$sha" \
  FAKE_ASSET_DIR="$extra_assets_dir" \
  "$ROOT_DIR/scripts/verify-published-release.sh" \
    --repo ourostack/ouro-workbench \
    --tag "$tag" \
    --version "$WORKBENCH_VERSION" \
    --sha "$sha" \
    --prerelease true \
    --skip-install >/dev/null 2>"$TEMP_ROOT/extra-assets.err"
extra_assets_status=$?
set -e
if [[ "$extra_assets_status" -eq 0 ]]; then
  printf 'Published release verifier selftest failed: extra assets unexpectedly passed\n' >&2
  exit 1
fi
grep -Fq 'expected exactly one public .zip asset' "$TEMP_ROOT/extra-assets.err" || {
  printf 'Published release verifier selftest failed: extra asset diagnostic missing\n' >&2
  cat "$TEMP_ROOT/extra-assets.err" >&2
  exit 1
}

bad_provenance_dir="$TEMP_ROOT/bad-provenance-assets"
mkdir -p "$bad_provenance_dir"
cp "$clean_asset_dir/$clean_archive_name" "$bad_provenance_dir/$clean_archive_name"
cp "$clean_asset_dir/$clean_manifest_name" "$bad_provenance_dir/$clean_manifest_name"
plutil -replace gitSha -string "0000000000000000000000000000000000000000" "$bad_provenance_dir/$clean_manifest_name"
set +e
GH_BIN="$fake_gh" \
  FAKE_TAG="$tag" \
  FAKE_SHA="$sha" \
  FAKE_ASSET_DIR="$bad_provenance_dir" \
  "$ROOT_DIR/scripts/verify-published-release.sh" \
    --repo ourostack/ouro-workbench \
    --tag "$tag" \
    --version "$WORKBENCH_VERSION" \
    --sha "$sha" \
    --prerelease true \
    --skip-install >/dev/null 2>"$TEMP_ROOT/bad-provenance.err"
bad_provenance_status=$?
set -e
if [[ "$bad_provenance_status" -eq 0 ]]; then
  printf 'Published release verifier selftest failed: bad artifact provenance unexpectedly passed\n' >&2
  exit 1
fi
grep -Fq 'gitSha is 0000000000000000000000000000000000000000' "$TEMP_ROOT/bad-provenance.err" || {
  printf 'Published release verifier selftest failed: bad provenance diagnostic missing\n' >&2
  cat "$TEMP_ROOT/bad-provenance.err" >&2
  exit 1
}

dirty_provenance_dir="$TEMP_ROOT/dirty-provenance-assets"
mkdir -p "$dirty_provenance_dir"
cp "$clean_asset_dir/$clean_archive_name" "$dirty_provenance_dir/$clean_archive_name"
cp "$clean_asset_dir/$clean_manifest_name" "$dirty_provenance_dir/$clean_manifest_name"
plutil -replace gitDirty -bool true "$dirty_provenance_dir/$clean_manifest_name"
set +e
GH_BIN="$fake_gh" \
  FAKE_TAG="$tag" \
  FAKE_SHA="$sha" \
  FAKE_ASSET_DIR="$dirty_provenance_dir" \
  "$ROOT_DIR/scripts/verify-published-release.sh" \
    --repo ourostack/ouro-workbench \
    --tag "$tag" \
    --version "$WORKBENCH_VERSION" \
    --sha "$sha" \
    --prerelease true \
    --skip-install >/dev/null 2>"$TEMP_ROOT/dirty-provenance.err"
dirty_provenance_status=$?
set -e
if [[ "$dirty_provenance_status" -eq 0 ]]; then
  printf 'Published release verifier selftest failed: dirty artifact provenance unexpectedly passed\n' >&2
  exit 1
fi
grep -Fq 'gitDirty is true' "$TEMP_ROOT/dirty-provenance.err" || {
  printf 'Published release verifier selftest failed: dirty provenance diagnostic missing\n' >&2
  cat "$TEMP_ROOT/dirty-provenance.err" >&2
  exit 1
}

grep -Fq 'scripts/verify-published-release.sh' "$ROOT_DIR/.github/workflows/release.yml" || {
  printf 'Release workflow must call scripts/verify-published-release.sh after publishing.\n' >&2
  exit 1
}
grep -Fq 'scripts/install-latest-release.sh' "$ROOT_DIR/scripts/verify-published-release.sh" || {
  printf 'Published release verifier must exercise the release installer path.\n' >&2
  exit 1
}
grep -Fq 'WEB_INSTALLER_URL' "$ROOT_DIR/scripts/verify-published-release.sh" || {
  printf 'Published release verifier must fetch and run the hosted public web installer.\n' >&2
  exit 1
}
grep -Fq 'raw.githubusercontent.com/${REPO}/${EXPECTED_SHA}/web/workbench-install.sh' "$ROOT_DIR/scripts/verify-published-release.sh" || {
  printf 'Published release verifier must derive its default hosted installer from the expected release SHA.\n' >&2
  exit 1
}
grep -Fq 'cmp -s "$WEB_INSTALLER_SOURCE" "$hosted_installer"' "$ROOT_DIR/scripts/verify-published-release.sh" || {
  printf 'Published release verifier must require the hosted installer to match the source copy.\n' >&2
  exit 1
}

printf 'Published release verifier selftest passed\n'
