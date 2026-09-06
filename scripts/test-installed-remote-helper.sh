#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper=${1:-$repo_root/.build/debug/OuroWorkbenchRemote}
helper="$(cd -- "$(dirname -- "$helper")" && pwd -P)/$(basename -- "$helper")"
test_root=$(mktemp -d /tmp/ouro-remote-installed.XXXXXX)
export LLVM_PROFILE_FILE="$test_root/helper-%p.profraw"
cleanup() {
  chmod -R u+rwX "$test_root" 2>/dev/null || true
  rm -rf "$test_root"
}
trap cleanup EXIT
chmod 700 "$test_root"

source_root=$test_root/source
mkdir -p "$source_root"
git -C "$source_root" init --quiet
git -C "$source_root" config user.name 'Remote Fixture'
git -C "$source_root" config user.email 'remote@example.test'
git -C "$source_root" config commit.gpgsign false
printf '%s\n' trusted-source > "$source_root/tracked.txt"
git -C "$source_root" add tracked.txt
git -C "$source_root" commit --quiet -m fixture
revision=$(git -C "$source_root" rev-parse --verify 'HEAD^{commit}')
helper_sha256=$(shasum -a 256 "$helper" | awk '{print $1}')
artifact=$test_root/artifact
runtime=$test_root/runtime
(
  cd "$source_root"
  "$helper" package --revision "$revision" --expected-helper-sha256 "$helper_sha256" --output "$artifact" >/dev/null
)
if "$helper" install --runtime-root "$runtime" --artifact-root "$artifact" --revision "$revision" --expected-helper-sha256 "$(printf 'b%.0s' {1..64})" >/dev/null 2>&1; then
  printf '%s\n' 'install accepted a helper outside the trusted digest' >&2
  exit 1
fi
test ! -e "$runtime"
"$helper" install --runtime-root "$runtime" --artifact-root "$artifact" --revision "$revision" --expected-helper-sha256 "$helper_sha256" | jq -e --arg revision "$revision" '.revision == $revision' >/dev/null

installed=$runtime/versions/$revision/bin/OuroWorkbenchRemote
test -x "$installed"
test "$(cat "$runtime/current")" = "$revision"
test "$(stat -f '%Lp' "$runtime")" = 700
test "$(stat -f '%Lp' "$runtime/current")" = 600
test "$(shasum -a 256 "$helper" | awk '{print $1}')" = "$(shasum -a 256 "$installed" | awk '{print $1}')"

mv "$artifact" "$test_root/artifact-away"
test "$("$installed" --version)" = 'OuroWorkbenchRemote 0.1.0'
"$installed" rollback --runtime-root "$runtime" --revision "$revision" | jq -e '.result == "retainedForNativeResume"' >/dev/null
test -x "$installed"
test "$(cat "$runtime/current")" = "$revision"

printf '%s\n' second-revision >> "$source_root/tracked.txt"
git -C "$source_root" add tracked.txt
git -C "$source_root" commit --quiet -m second-fixture
second_revision=$(git -C "$source_root" rev-parse --verify 'HEAD^{commit}')
second_artifact=$test_root/second-artifact
(
  cd "$source_root"
  "$helper" package --revision "$second_revision" --expected-helper-sha256 "$helper_sha256" --output "$second_artifact" >/dev/null
)
"$helper" install --runtime-root "$runtime" --artifact-root "$second_artifact" --revision "$second_revision" --expected-helper-sha256 "$helper_sha256" >/dev/null
second_installed=$runtime/versions/$second_revision/bin/OuroWorkbenchRemote
test "$(cat "$runtime/current")" = "$second_revision"
"$second_installed" rollback --runtime-root "$runtime" --revision "$revision" | jq -e '.result == "removed"' >/dev/null
test ! -e "$runtime/versions/$revision"

printf '%s\n' 'installed remote helper smoke ok'
