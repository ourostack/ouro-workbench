#!/usr/bin/env bash
#
# Coverage gate for pure Workbench logic targets.
#
# OuroWorkbenchCore is the pure, framework-free logic of the workbench (the GUI
# shell lives in OuroWorkbenchApp and is not gated here). The shell adapter target
# is also pure presenter logic, so it is held to the same bar. Because the product
# is agentically authored, every file under these source roots must be 100% line
# AND region covered. This script fails if any file is below 100%.
#
# Region, not branch: Swift's --enable-code-coverage emits no llvm branch counters
# (llvm-cov's Branch column is always empty for Swift). Region coverage is the
# Swift-native equivalent — one region per conditional arm — so 100% region means
# every branch was taken.
#
# Gate flakiness — handled at the ROOT, NOT by a CI retry. The two intermittent-flake
# classes (TIMING-RACE tests + Apple Swift 6.0.3 SYNTHESIZED-EPILOGUE braces) are
# documented in scripts/coverage-allowlist.txt's header with a cover-first-then-minimal-1/1
# protocol. A 2026-06 proactive sweep hardened every at-risk timeout test to a generous
# budget and pre-allowlisted the (only three) genuinely-synthesized braces, so the gate is
# deterministic. DECISION: NO single-retry backstop on this job — a retry would mask not just
# coverage flakes but any GENUINE intermittent test failure (the exact instability we want
# surfaced), and with the root causes fixed it buys nothing but doubled CI time on a real RED.
# Any future flake is diagnosed + handled per the allowlist protocol (cover-first, then 1/1).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

test_log=""
profile_root=""
cleanup() {
  [ -z "${test_log:-}" ] || rm -f "$test_log"
  [ -z "${profile_root:-}" ] || rm -rf "$profile_root"
}
trap cleanup EXIT

COVERAGE_DIRS=(
  "Sources/OuroWorkbenchCore"
  "Sources/OuroWorkbenchShellAdapter"
  # U5 Unit 3: gate the views file (a single-file entry). A path ending in `.swift` is
  # matched as an exact file; a path without one is matched as a directory.
  "Sources/OuroWorkbenchAppViews/WorkbenchViews.swift"
  # VM-GATE campaign: the VM file is now GATED too — its sibling logic half of the U5 split.
  # It enters at its CI-measured residual allowlist and the per-cluster drive lowers it to the
  # irreducible floor (live-PTY/subprocess syscalls + .task loops + llvm-synth artifacts), same
  # as how WorkbenchViews.swift landed (379→227). See coverage-allowlist.txt + vm-gate-scope.md.
  "Sources/OuroWorkbenchAppViews/WorkbenchViewModel.swift"
)

if [ -d /Applications ]; then
  latest="$(ls -d /Applications/Xcode_16*.app 2>/dev/null | sort -V | tail -1 || true)"
  [ -z "${latest:-}" ] && latest="$(ls -d /Applications/Xcode_*.app 2>/dev/null | sort -V | tail -1 || true)"
  [ -n "${latest:-}" ] && export DEVELOPER_DIR="$latest/Contents/Developer"
fi

if [ "${1:-}" != "--no-build" ]; then
  profile_root="$(mktemp -d -t ouro-workbench-coverage-profiles.XXXXXX)"

  # `swift test --enable-code-coverage` with no filter runs every XCTest target in
  # one long AppKit process. On macOS that all-target process can wake the
  # Contacts/CoreData XPC store during test discovery/rendering even though each
  # target-selected suite is hermetic. Run the coverage gate in target shards,
  # enforce the no-Contacts-noise contract per shard, then merge the saved raw
  # profiles so the line+region gate below is still computed over every test.
  run_coverage_shard() {
    local name="$1"
    local filter="$2"
    local shard_dir="$profile_root/$name"
    local raw_count=0
    mkdir -p "$shard_dir"

    if [ -d .build ]; then
      find .build -path '*/codecov/*.profraw' -exec rm -f {} +
      find .build -path '*/codecov/default.profdata' -exec rm -f {} +
    fi

    test_log="$(mktemp -t "ouro-workbench-coverage-$name.XXXXXX.log")"
    echo "==> swift test --enable-code-coverage --filter '$filter'"
    set +e
    swift test --enable-code-coverage --filter "$filter" 2>&1 | tee "$test_log"
    test_status="${PIPESTATUS[0]}"
    set -e

    scripts/check-test-log-noise.sh "coverage shard '$name'" "$test_log"
    if [ "$test_status" -ne 0 ]; then
      echo ""
      echo "FAIL: coverage shard '$name' failed." >&2
      exit "$test_status"
    fi

    while IFS= read -r -d '' raw; do
      cp "$raw" "$shard_dir/"
      raw_count=$((raw_count + 1))
    done < <(find .build -path '*/codecov/*.profraw' -print0)
    if [ "$raw_count" -eq 0 ]; then
      echo "FAIL: coverage shard '$name' produced no raw coverage profiles." >&2
      exit 1
    fi

    rm -f "$test_log"
    test_log=""
  }

  run_coverage_shard "appviews" "OuroWorkbenchAppViewsTests"
  run_coverage_shard "core" "OuroWorkbenchCoreTests|OuroWorkbenchShellAdapterTests"

  raw_profiles=()
  while IFS= read -r -d '' raw; do
    raw_profiles+=("$raw")
  done < <(find "$profile_root" -name '*.profraw' -print0)
  if [ "${#raw_profiles[@]}" -eq 0 ]; then
    echo "FAIL: no coverage profiles were saved from the coverage shards." >&2
    exit 1
  fi
  mkdir -p .build
  xcrun llvm-profdata merge -sparse "${raw_profiles[@]}" -o .build/wb-coverage.profdata
fi

bin="$(find .build -name '*PackageTests' -type f -path '*MacOS*' ! -path '*dSYM*' | head -1)"
prof=".build/wb-coverage.profdata"
if [ ! -f "$prof" ]; then
  prof="$(find .build -name 'default.profdata' | head -1)"
fi
if [ -z "$bin" ] || [ -z "$prof" ]; then
  echo "error: could not locate coverage artifacts (binary='$bin' profdata='$prof')" >&2
  exit 1
fi

xcrun llvm-cov export "$bin" -instr-profile "$prof" -summary-only "${COVERAGE_DIRS[@]}" > .build/wb-coverage.json

python3 - "${COVERAGE_DIRS[@]}" <<'PY'
import json, os, sys

coverage_dirs = sys.argv[1:]
with open('.build/wb-coverage.json') as fh:
    data = json.load(fh)

def is_covered_source(filename):
    # An entry ending in `.swift` is an exact-file gate (match the path suffix so
    # only THAT file is held to 100%, not its directory siblings). Any other entry
    # is a directory gate (match the `/dir/` path segment).
    for entry in coverage_dirs:
        if entry.endswith('.swift'):
            if filename.endswith('/' + entry) or filename == entry:
                return True
        elif f'/{entry}/' in filename:
            return True
    return False

files = [f for f in data['data'][0]['files'] if is_covered_source(f['filename'])]
if not files:
    print(f'error: no covered source files in coverage data: {coverage_dirs}', file=sys.stderr)
    sys.exit(1)

# Allowlist of intentionally-uncovered code that no test can reach (structurally
# unreachable). Format per line: <File.swift> <max_uncovered_lines> <max_uncovered_regions>
allow = {}
allow_path = 'scripts/coverage-allowlist.txt'
if os.path.exists(allow_path):
    with open(allow_path) as fh:
        for raw in fh:
            line = raw.split('#', 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            allow[parts[0]] = (int(parts[1]), int(parts[2]))

below = []
exempt = []
for f in files:
    name = os.path.basename(f['filename'])
    L = f['summary']['lines']
    R = f['summary']['regions']
    ul = L['count'] - L['covered']
    ur = R['count'] - R['covered']
    if ul == 0 and ur == 0:
        continue
    al, ar = allow.get(name, (0, 0))
    if ul <= al and ur <= ar:
        exempt.append((name, ul, ur))
    else:
        below.append((ul, name, L['percent'], R['percent'], ur, f['filename']))

total_files = len(files)
fully = total_files - len(below) - len(exempt)
label = ', '.join(coverage_dirs)
print(f'\n{label}: {fully}/{total_files} files at 100% line+region'
      + (f' ({len(exempt)} with allowlisted structural exclusions)' if exempt else ''))
for name, ul, ur in sorted(exempt):
    print(f'  allow {name:44} ({ul} line, {ur} region exempt — see coverage-allowlist.txt)')

with open('.build/wb-below.txt', 'w') as fh:
    if below:
        below.sort(reverse=True)
        print(f'\n{len(below)} below 100%:')
        for ul, name, lp, rp, ur, path in below:
            print(f'  {name:44} {lp:5.1f}% line  {rp:5.1f}% region  ({ul} lines / {ur} regions uncovered)')
            fh.write(path + '\n')
PY

# If any file is below 100%, dump its exact uncovered lines/regions so the CI log
# self-reports what THIS toolchain's llvm-cov sees (coverage can differ across
# Swift versions), then fail. The diagnostic uses the same artifacts as above.
if [ -s .build/wb-below.txt ]; then
  echo ""
  echo "==> uncovered detail (per failing file, as seen by $(xcrun swift --version 2>/dev/null | head -1)):"
  while IFS= read -r srcfile; do
    [ -n "$srcfile" ] || continue
    echo ""
    echo "--- $srcfile ---"
    echo "  uncovered LINES:"
    xcrun llvm-cov show "$bin" -instr-profile "$prof" "$srcfile" 2>/dev/null \
      | grep -E '^\s*[0-9]+\|\s*0\|' | sed 's/^/    /' || echo "    (none fully-uncovered; gaps are partial regions)"
    echo "  uncovered REGIONS (branch arms):"
    xcrun llvm-cov show "$bin" -instr-profile "$prof" "$srcfile" --show-regions 2>/dev/null \
      | grep -B1 -E '^\s+\^0([^0-9]|$)' | grep -vE '^\s+\^0|^--' | sed 's/^/    /' | head -40 || true
  done < .build/wb-below.txt
  echo ""
  echo "FAIL: pure Workbench logic targets must be 100% line + region covered (minus the documented allowlist)."
  exit 1
fi
echo ""
echo "PASS: pure Workbench logic targets are 100% line + region covered (documented structural exclusions aside)."
