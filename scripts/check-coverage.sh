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

COVERAGE_DIRS=(
  "Sources/OuroWorkbenchCore"
  "Sources/OuroWorkbenchShellAdapter"
  # U5 Unit 3: gate ONLY the views file (a single-file entry), NOT its sibling
  # WorkbenchViewModel.swift in the same directory — that file holds the live-PTY /
  # live-subprocess machinery that is intentionally ungated. A path ending in
  # `.swift` is matched as an exact file; a path without one is matched as a directory.
  "Sources/OuroWorkbenchAppViews/WorkbenchViews.swift"
  # VM-GATE campaign STEP 1 (SCOPING): wire the VM file into the gate to MEASURE its
  # residual on CI. No allowlist entry yet — the gate WILL FAIL and dump the exact
  # uncovered line/region count, which is the scoping data. The per-cluster drive then
  # lowers it to the irreducible floor before this becomes a permanent gate entry.
  "Sources/OuroWorkbenchAppViews/WorkbenchViewModel.swift"
)

if [ -d /Applications ]; then
  latest="$(ls -d /Applications/Xcode_16*.app 2>/dev/null | sort -V | tail -1 || true)"
  [ -z "${latest:-}" ] && latest="$(ls -d /Applications/Xcode_*.app 2>/dev/null | sort -V | tail -1 || true)"
  [ -n "${latest:-}" ] && export DEVELOPER_DIR="$latest/Contents/Developer"
fi

if [ "${1:-}" != "--no-build" ]; then
  echo "==> swift test --enable-code-coverage"
  swift test --enable-code-coverage
fi

bin="$(find .build -name '*PackageTests' -type f -path '*MacOS*' ! -path '*dSYM*' | head -1)"
prof="$(find .build -name 'default.profdata' | head -1)"
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
