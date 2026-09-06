#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper=${1:-$repo_root/.build/debug/OuroWorkbenchRemote}
helper="$(cd -- "$(dirname -- "$helper")" && pwd -P)/$(basename -- "$helper")"
test_root=$(mktemp -d /tmp/ouro-remote-package.XXXXXX)
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

(
  cd "$source_root"
  "$helper" package --revision "$revision" --expected-helper-sha256 "$helper_sha256" --output "$artifact" >/dev/null
)

test -x "$artifact/bin/OuroWorkbenchRemote"
test "$(stat -f '%Lp' "$artifact")" = 700
test "$(stat -f '%Lp' "$artifact/bin/OuroWorkbenchRemote")" = 755
test "$(stat -f '%Lp' "$artifact/manifest.json")" = 600
jq -e --arg revision "$revision" '
  .schemaVersion == 1 and
  .revision == $revision and
  .files == [{"mode":493,"relativePath":"bin/OuroWorkbenchRemote","sha256":.files[0].sha256}] and
  (.files[0].sha256 | test("^[0-9a-f]{64}$"))
' "$artifact/manifest.json" >/dev/null
test "$(jq -r '.files[0].sha256' "$artifact/manifest.json")" = "$(shasum -a 256 "$artifact/bin/OuroWorkbenchRemote" | awk '{print $1}')"

if (cd "$source_root" && "$helper" package --revision not-a-revision --expected-helper-sha256 "$helper_sha256" --output "$test_root/bad" >/dev/null 2>&1); then
  printf '%s\n' 'package accepted an invalid revision' >&2
  exit 1
fi
if (cd "$source_root" && "$helper" package --revision "$revision" --expected-helper-sha256 "$helper_sha256" --output "$artifact" >/dev/null 2>&1); then
  printf '%s\n' 'package replaced an existing artifact' >&2
  exit 1
fi
if (cd "$source_root" && "$helper" package --revision "$revision" --expected-helper-sha256 "$(printf 'b%.0s' {1..64})" --output "$test_root/untrusted" >/dev/null 2>&1); then
  printf '%s\n' 'package accepted a helper outside the trusted digest' >&2
  exit 1
fi

printf '%s\n' dirt > "$source_root/untracked.txt"
if (cd "$source_root" && "$helper" package --revision "$revision" --expected-helper-sha256 "$helper_sha256" --output "$test_root/dirty" >/dev/null 2>&1); then
  printf '%s\n' 'package accepted a dirty source checkout' >&2
  exit 1
fi

printf '%s\n' 'remote helper package smoke ok'
