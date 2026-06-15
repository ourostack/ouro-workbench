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

below = []
for f in files:
    L = f['summary']['lines']
    R = f['summary']['regions']
    if L['covered'] != L['count'] or R['covered'] != R['count']:
        below.append((L['count'] - L['covered'], os.path.basename(f['filename']),
                      L['percent'], R['percent']))

total_files = len(files)
ok_files = total_files - len(below)
print(f'\nOuroWorkbenchCore: {ok_files}/{total_files} files at 100% line+region')
if below:
    below.sort(reverse=True)
    print(f'{len(below)} below 100% ({sum(b[0] for b in below)} uncovered lines):')
    for uncov, name, lp, rp in below:
        print(f'  {name:44} {lp:5.1f}% line  {rp:5.1f}% region  ({uncov} uncovered lines)')
    print('\nFAIL: OuroWorkbenchCore must be 100% line + region covered.')
    sys.exit(1)
print('\nPASS: OuroWorkbenchCore is 100% line + region covered.')
PY
