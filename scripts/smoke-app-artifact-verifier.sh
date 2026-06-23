#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$("$ROOT_DIR/scripts/read-workbench-release.sh")"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ouro-workbench-artifact-smoke.XXXXXX")"

cleanup() {
  rm -rf "$TEMP_ROOT"
}

trap cleanup EXIT

latest_manifest="$(find "$ARTIFACTS_DIR" -name "$WORKBENCH_ARTIFACT_NAME_PREFIX*.manifest.json" -type f -print | sort | tail -n 1)"
if [[ -z "$latest_manifest" ]]; then
  printf 'App artifact smoke failed: no manifest found in %s\n' "$ARTIFACTS_DIR" >&2
  exit 1
fi

"$ROOT_DIR/scripts/verify-app-artifact.sh" "$latest_manifest" >/dev/null

archive_name="$(plutil -extract archive raw -o - "$latest_manifest")"
archive_path="$(dirname "$latest_manifest")/$archive_name"
copied_manifest="$TEMP_ROOT/$(basename "$latest_manifest")"
copied_archive="$TEMP_ROOT/$archive_name"
cp "$latest_manifest" "$copied_manifest"
cp "$archive_path" "$copied_archive"
printf 'corruption\n' >> "$copied_archive"

set +e
"$ROOT_DIR/scripts/verify-app-artifact.sh" "$copied_manifest" "$copied_archive" >/dev/null 2>"$TEMP_ROOT/corrupt.err"
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  printf 'App artifact smoke failed: corrupt archive unexpectedly verified\n' >&2
  exit 1
fi

printf 'App artifact verifier smoke passed\n'
