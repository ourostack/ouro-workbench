#!/usr/bin/env bash
#
# Coverage gate for OuroWorkbenchCore.
#
# OuroWorkbenchCore is the pure, framework-free logic of the workbench (the GUI
# shell lives in OuroWorkbenchApp and is not gated here). Because the product is
# agentically authored, every file under Sources/OuroWorkbenchCore/ must be 100%
# line AND region covered. This script fails if any file is below 100%.
#
# Region, not branch: Swift's --enable-code-coverage emits no llvm branch counters
# (llvm-cov's Branch column is always empty for Swift). Region coverage is the
# Swift-native equivalent — one region per conditional arm — so 100% region means
# every branch was taken.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

CORE_DIR="Sources/OuroWorkbenchCore"

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

xcrun llvm-cov export "$bin" -instr-profile "$prof" -summary-only "$CORE_DIR" > .build/wb-coverage.json

python3 - "$CORE_DIR" <<'PY'
import json, os, sys

core_dir = sys.argv[1]
with open('.build/wb-coverage.json') as fh:
    data = json.load(fh)

files = [f for f in data['data'][0]['files'] if f'/{core_dir}/' in f['filename']]
if not files:
    print(f'error: no {core_dir} files in coverage data', file=sys.stderr)
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
        below.append((ul, name, L['percent'], R['percent'], ur))

total_files = len(files)
fully = total_files - len(below) - len(exempt)
print(f'\nOuroWorkbenchCore: {fully}/{total_files} files at 100% line+region'
      + (f' ({len(exempt)} with allowlisted structural exclusions)' if exempt else ''))
for name, ul, ur in sorted(exempt):
    print(f'  allow {name:44} ({ul} line, {ur} region exempt — see coverage-allowlist.txt)')
if below:
    below.sort(reverse=True)
    print(f'\n{len(below)} below 100%:')
    for ul, name, lp, rp, ur in below:
        print(f'  {name:44} {lp:5.1f}% line  {rp:5.1f}% region  ({ul} lines / {ur} regions uncovered)')
    print('\nFAIL: OuroWorkbenchCore must be 100% line + region covered (minus the documented allowlist).')
    sys.exit(1)
print('\nPASS: OuroWorkbenchCore is 100% line + region covered (documented structural exclusions aside).')
PY
