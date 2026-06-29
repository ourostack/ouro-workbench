#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SWIFT_STRICT_FLAGS=(-Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete)

test_log=""
cleanup() {
  [ -z "${test_log:-}" ] || rm -f "$test_log"
}
trap cleanup EXIT

run_test_shard() {
  local name="$1"
  local filter="$2"
  local status=0

  test_log="$(mktemp -t "ouro-workbench-swift-tests-$name.XXXXXX.log")"
  echo "==> swift test ${SWIFT_STRICT_FLAGS[*]} --filter '$filter'"
  set +e
  swift test "${SWIFT_STRICT_FLAGS[@]}" --filter "$filter" 2>&1 | tee "$test_log"
  status="${PIPESTATUS[0]}"
  set -e

  scripts/check-test-log-noise.sh "Swift test shard '$name'" "$test_log"
  if [ "$status" -ne 0 ]; then
    echo ""
    echo "FAIL: Swift test shard '$name' failed." >&2
    exit "$status"
  fi

  rm -f "$test_log"
  test_log=""
}

# Keep regular Swift-test preflight/CI on the same hermetic contract as coverage:
# the unfiltered all-target XCTest process can wake macOS Contacts/CoreData/XPC,
# while target-selected shards exercise the same test suites without that noise.
run_test_shard "appviews" "OuroWorkbenchAppViewsTests"
run_test_shard "core" "OuroWorkbenchCoreTests"
