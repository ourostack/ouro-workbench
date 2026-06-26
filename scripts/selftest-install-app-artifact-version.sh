#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$("$ROOT_DIR/scripts/read-workbench-release.sh")"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ouro-workbench-install-version-selftest.XXXXXX")"
INSTALL_DIR="$TEMP_ROOT/Applications"
CALL_LOG="$TEMP_ROOT/verifier-calls.log"

cleanup() {
  rm -rf "$TEMP_ROOT"
}

trap cleanup EXIT

latest_manifest="$(find "$ARTIFACTS_DIR" -name "$WORKBENCH_ARTIFACT_NAME_PREFIX*.manifest.json" -type f -print | sort | tail -n 1)"
if [[ -z "$latest_manifest" ]]; then
  printf 'Install artifact version selftest failed: no manifest found in %s\n' "$ARTIFACTS_DIR" >&2
  exit 1
fi

expected_version="$(plutil -extract version raw -o - "$latest_manifest")"
verifier="$TEMP_ROOT/require-manifest-version-verifier.sh"
cat > "$verifier" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

: "${EXPECTED_VERSION:?}"
: "${REAL_VERIFIER:?}"
: "${CALL_LOG:?}"

args=("$@")
found_expected_version="false"
for ((index = 0; index < ${#args[@]}; index++)); do
  if [[ "${args[$index]}" == "--expected-version" ]]; then
    next_index=$((index + 1))
    if [[ "$next_index" -lt "${#args[@]}" && "${args[$next_index]}" == "$EXPECTED_VERSION" ]]; then
      found_expected_version="true"
    fi
  fi
done

if [[ "$found_expected_version" != "true" ]]; then
  printf 'Verifier was not called with --expected-version %s: %q\n' "$EXPECTED_VERSION" "$*" >&2
  exit 1
fi

printf 'verified\n' >> "$CALL_LOG"
"$REAL_VERIFIER" "$@"
SH
chmod +x "$verifier"

mkdir -p "$INSTALL_DIR"
EXPECTED_VERSION="$expected_version" \
  REAL_VERIFIER="$ROOT_DIR/scripts/verify-app-bundle.sh" \
  CALL_LOG="$CALL_LOG" \
  "$ROOT_DIR/scripts/install-app.sh" \
    --install-dir "$INSTALL_DIR" \
    --artifact-manifest "$latest_manifest" \
    --verify-script "$verifier" >/dev/null

call_count="$(wc -l < "$CALL_LOG" | tr -d '[:space:]')"
if [[ "$call_count" != "2" ]]; then
  printf 'Install artifact version selftest failed: expected 2 verifier calls, saw %s\n' "$call_count" >&2
  exit 1
fi

"$ROOT_DIR/scripts/verify-app-bundle.sh" "$INSTALL_DIR/$WORKBENCH_APP_NAME.app" --expected-version "$expected_version" >/dev/null

printf 'Install artifact version selftest passed\n'
