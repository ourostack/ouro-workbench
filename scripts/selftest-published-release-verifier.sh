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
mkdir -p "$clean_asset_dir"
cp "$latest_archive" "$clean_asset_dir/$clean_archive_name"
cp "$latest_manifest" "$clean_asset_dir/$clean_manifest_name"
plutil -replace archive -string "$clean_archive_name" "$clean_asset_dir/$clean_manifest_name"
plutil -replace gitSha -string "$sha" "$clean_asset_dir/$clean_manifest_name"
plutil -replace gitDirty -bool false "$clean_asset_dir/$clean_manifest_name"
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
    pattern=""
    destination=""
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        --repo)
          shift 2
          ;;
        --pattern)
          pattern="${2:-}"
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
    [[ -n "$pattern" && -n "$destination" ]] || exit 64
    mkdir -p "$destination"
    cp "$FAKE_ASSET_DIR/$pattern" "$destination/"
    ;;
  *)
    printf 'unsupported fake gh release command: %s\n' "$command" >&2
    exit 99
    ;;
esac
SH
chmod +x "$fake_gh"

GH_BIN="$fake_gh" \
  FAKE_TAG="$tag" \
  FAKE_SHA="$sha" \
  FAKE_ASSET_DIR="$clean_asset_dir" \
  "$ROOT_DIR/scripts/verify-published-release.sh" \
    --repo ourostack/ouro-workbench \
    --tag "$tag" \
    --version "$WORKBENCH_VERSION" \
    --sha "$sha" \
    --prerelease true \
    --skip-install >/dev/null

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

printf 'Published release verifier selftest passed\n'
