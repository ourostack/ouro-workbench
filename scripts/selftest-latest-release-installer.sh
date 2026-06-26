#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEMP_ROOT"' EXIT

FAKE_BIN="$TEMP_ROOT/bin"
FAKE_LOG="$TEMP_ROOT/gh.log"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$GH_FAKE_LOG"

if [[ "$#" -ge 2 && "$1" == "release" && "$2" == "view" ]]; then
  printf 'release not found\n' >&2
  exit 1
fi

if [[ "$#" -ge 2 && "$1" == "release" && "$2" == "list" ]]; then
  args=" $* "
  [[ "$args" == *" --repo ourostack/ouro-workbench "* ]] || {
    printf 'expected --repo ourostack/ouro-workbench, got: %s\n' "$*" >&2
    exit 2
  }
  [[ "$args" == *" --exclude-drafts "* ]] || {
    printf 'expected --exclude-drafts, got: %s\n' "$*" >&2
    exit 2
  }
  [[ "$args" == *" --limit 1 "* ]] || {
    printf 'expected --limit 1, got: %s\n' "$*" >&2
    exit 2
  }
  [[ "$args" == *" --json tagName "* ]] || {
    printf 'expected --json tagName, got: %s\n' "$*" >&2
    exit 2
  }
  [[ "$args" == *" --jq .[0].tagName "* || "$args" == *" --jq '.[0].tagName' "* ]] || {
    printf 'expected --jq .[0].tagName, got: %s\n' "$*" >&2
    exit 2
  }
  if [[ "${GH_FAKE_EMPTY:-false}" == "true" ]]; then
    printf 'null\n'
  else
    printf 'v9.9.9-preview.1\n'
  fi
  exit 0
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 2
FAKE_GH
chmod +x "$FAKE_BIN/gh"

resolved="$(PATH="$FAKE_BIN:$PATH" GH_FAKE_LOG="$FAKE_LOG" \
  "$ROOT_DIR/scripts/resolve-latest-release-tag.sh" --repo ourostack/ouro-workbench)"

if [[ "$resolved" != "v9.9.9-preview.1" ]]; then
  printf 'Expected prerelease resolver to print v9.9.9-preview.1, got %s\n' "$resolved" >&2
  exit 1
fi

if grep -q '^release view' "$FAKE_LOG"; then
  printf 'Resolver called gh release view, which ignores prerelease-only latest releases.\n' >&2
  exit 1
fi

grep -q '^release list' "$FAKE_LOG" || {
  printf 'Resolver did not call gh release list.\n' >&2
  exit 1
}

set +e
PATH="$FAKE_BIN:$PATH" GH_FAKE_LOG="$FAKE_LOG" GH_FAKE_EMPTY=true \
  "$ROOT_DIR/scripts/resolve-latest-release-tag.sh" --repo ourostack/ouro-workbench \
  >"$TEMP_ROOT/empty.out" 2>"$TEMP_ROOT/empty.err"
empty_status=$?
set -e

if [[ "$empty_status" -eq 0 ]]; then
  printf 'Expected empty release list to fail.\n' >&2
  exit 1
fi

grep -q 'No release tag found for ourostack/ouro-workbench' "$TEMP_ROOT/empty.err" || {
  printf 'Expected empty release diagnostic, got:\n' >&2
  cat "$TEMP_ROOT/empty.err" >&2
  exit 1
}

grep -Fq 'scripts/resolve-latest-release-tag.sh' "$ROOT_DIR/scripts/install-latest-release.sh" || {
  printf 'install-latest-release.sh must use resolve-latest-release-tag.sh for default tag selection.\n' >&2
  exit 1
}

printf 'latest release installer selftest ok\n'
