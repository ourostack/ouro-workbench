#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$("$ROOT_DIR/scripts/read-workbench-release.sh")"
GH_BIN="${GH_BIN:-gh}"
REPO="$WORKBENCH_REPOSITORY"
VERSION="$WORKBENCH_VERSION"
TAG="v$VERSION"
EXPECTED_SHA=""
EXPECTED_PRERELEASE="true"
INSTALL_SMOKE="true"

usage() {
  cat <<USAGE
Usage: verify-published-release.sh [options]

Verify that the public GitHub Release exists, targets the expected commit,
publishes exactly one app archive and manifest, and installs through the
release installer path.

Options:
  --repo OWNER/REPO      GitHub repository (default: $REPO)
  --tag TAG              Release tag (default: $TAG)
  --version VERSION      Expected app version (default: $VERSION)
  --sha SHA              Expected target commit (default: current HEAD)
  --prerelease true|false
                         Expected GitHub prerelease flag (default: true)
  --skip-install         Skip installer smoke, used only by local selftests
  -h, --help             Show this help
USAGE
}

fail() {
  printf 'Published release verification failed: %s\n' "$1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      if [[ $# -lt 2 || -z "$2" ]]; then
        usage >&2
        exit 64
      fi
      REPO="$2"
      shift 2
      ;;
    --tag)
      if [[ $# -lt 2 || -z "$2" ]]; then
        usage >&2
        exit 64
      fi
      TAG="$2"
      shift 2
      ;;
    --version)
      if [[ $# -lt 2 || -z "$2" ]]; then
        usage >&2
        exit 64
      fi
      VERSION="$2"
      shift 2
      ;;
    --sha)
      if [[ $# -lt 2 || -z "$2" ]]; then
        usage >&2
        exit 64
      fi
      EXPECTED_SHA="$2"
      shift 2
      ;;
    --prerelease)
      if [[ $# -lt 2 || ! "$2" =~ ^(true|false)$ ]]; then
        usage >&2
        exit 64
      fi
      EXPECTED_PRERELEASE="$2"
      shift 2
      ;;
    --skip-install)
      INSTALL_SMOKE="false"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

if ! command -v "$GH_BIN" >/dev/null 2>&1 && [[ ! -x "$GH_BIN" ]]; then
  fail "GitHub CLI is required to inspect release $TAG"
fi
if [[ -z "$EXPECTED_SHA" ]]; then
  EXPECTED_SHA="$(git -C "$ROOT_DIR" rev-parse HEAD)"
fi

release_value() {
  local field="$1"
  "$GH_BIN" release view "$TAG" --repo "$REPO" --json "$field" --jq ".$field"
}

actual_tag=""
for attempt in $(seq 1 18); do
  if actual_tag="$(release_value tagName 2>/dev/null)"; then
    break
  fi
  sleep 5
done
[[ -n "$actual_tag" ]] || fail "release $TAG was not visible"
[[ "$actual_tag" == "$TAG" ]] || fail "release tag is $actual_tag, expected $TAG"

latest_tag="$("$GH_BIN" release list --repo "$REPO" --exclude-drafts --limit 1 --json tagName --jq '.[0].tagName')"
[[ "$latest_tag" == "$TAG" ]] || fail "latest release is $latest_tag, expected $TAG"

is_draft="$(release_value isDraft)"
is_prerelease="$(release_value isPrerelease)"
target="$(release_value targetCommitish)"
target_sha="$(git -C "$ROOT_DIR" rev-parse "$target^{commit}" 2>/dev/null || printf '%s' "$target")"
expected_short_sha="$(git -C "$ROOT_DIR" rev-parse --short "$EXPECTED_SHA^{commit}" 2>/dev/null || printf '%.7s' "$EXPECTED_SHA")"

[[ "$is_draft" == "false" ]] || fail "$TAG is still a draft"
[[ "$is_prerelease" == "$EXPECTED_PRERELEASE" ]] || fail "$TAG prerelease flag is $is_prerelease, expected $EXPECTED_PRERELEASE"
[[ "$target_sha" == "$EXPECTED_SHA" ]] || fail "$TAG targets $target_sha, expected $EXPECTED_SHA"

zip_asset=""
manifest_asset=""
zip_count=0
manifest_count=0
while IFS= read -r asset_name; do
  case "$asset_name" in
    ${WORKBENCH_ARTIFACT_NAME_PREFIX}${VERSION}-build.*.zip)
      zip_asset="$asset_name"
      zip_count=$((zip_count + 1))
      ;;
    ${WORKBENCH_ARTIFACT_NAME_PREFIX}${VERSION}-build.*.manifest.json)
      manifest_asset="$asset_name"
      manifest_count=$((manifest_count + 1))
      ;;
  esac
done < <("$GH_BIN" release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name')

[[ "$zip_count" -eq 1 ]] || fail "expected exactly one $WORKBENCH_ARTIFACT_NAME_PREFIX$VERSION zip asset, found $zip_count"
[[ "$manifest_count" -eq 1 ]] || fail "expected exactly one $WORKBENCH_ARTIFACT_NAME_PREFIX$VERSION manifest asset, found $manifest_count"
case "$zip_asset" in
  *-"$expected_short_sha".zip) ;;
  *) fail "$zip_asset does not end with expected short SHA $expected_short_sha" ;;
esac
case "$manifest_asset" in
  *-"$expected_short_sha".manifest.json) ;;
  *) fail "$manifest_asset does not end with expected short SHA $expected_short_sha" ;;
esac

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ouro-workbench-published-release.XXXXXX")"
cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

"$GH_BIN" release download "$TAG" --repo "$REPO" --pattern "$zip_asset" --dir "$TEMP_ROOT" >/dev/null
"$GH_BIN" release download "$TAG" --repo "$REPO" --pattern "$manifest_asset" --dir "$TEMP_ROOT" >/dev/null

[[ -s "$TEMP_ROOT/$zip_asset" ]] || fail "downloaded zip is missing or empty: $zip_asset"
[[ -s "$TEMP_ROOT/$manifest_asset" ]] || fail "downloaded manifest is missing or empty: $manifest_asset"
"$ROOT_DIR/scripts/verify-app-artifact.sh" "$TEMP_ROOT/$manifest_asset" "$TEMP_ROOT/$zip_asset" >/dev/null
manifest_sha="$(plutil -extract gitSha raw -o - "$TEMP_ROOT/$manifest_asset" 2>/dev/null || true)"
manifest_dirty="$(plutil -extract gitDirty raw -o - "$TEMP_ROOT/$manifest_asset" 2>/dev/null || true)"
[[ "$manifest_sha" == "$EXPECTED_SHA" ]] || fail "$manifest_asset gitSha is $manifest_sha, expected $EXPECTED_SHA"
[[ "$manifest_dirty" == "false" ]] || fail "$manifest_asset gitDirty is $manifest_dirty, expected false"

if [[ "$INSTALL_SMOKE" == "true" ]]; then
  install_dir="$TEMP_ROOT/Applications"
  mkdir -p "$install_dir"
  "$ROOT_DIR/scripts/install-latest-release.sh" --repo "$REPO" --tag "$TAG" --install-dir "$install_dir" >/dev/null
  installed_app="$install_dir/$WORKBENCH_APP_NAME.app"
  "$ROOT_DIR/scripts/verify-app-bundle.sh" "$installed_app" --expected-version "$VERSION" >/dev/null
fi

printf 'Verified published release: %s (%s)\n' "$TAG" "$EXPECTED_SHA"
