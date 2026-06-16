#!/usr/bin/env bash
#
# Show the uncovered (zero-count) lines for one OuroWorkbenchCore source file,
# using the most recent coverage run. Run scripts/check-coverage.sh first (or
# `swift test --enable-code-coverage`) so the profdata exists.
#
#   scripts/coverage-show.sh Sources/OuroWorkbenchCore/Onboarding.swift
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

file="${1:?usage: coverage-show.sh <path-to-source-file>}"

if [ -d /Applications ]; then
  latest="$(ls -d /Applications/Xcode_16*.app 2>/dev/null | sort -V | tail -1 || true)"
  [ -z "${latest:-}" ] && latest="$(ls -d /Applications/Xcode_*.app 2>/dev/null | sort -V | tail -1 || true)"
  [ -n "${latest:-}" ] && export DEVELOPER_DIR="$latest/Contents/Developer"
fi

bin="$(find .build -name '*PackageTests' -type f -path '*MacOS*' ! -path '*dSYM*' | head -1)"
prof="$(find .build -name 'default.profdata' | head -1)"
[ -n "$bin" ] && [ -n "$prof" ] || { echo "no coverage artifacts; run scripts/check-coverage.sh first" >&2; exit 1; }

echo "== uncovered LINES in $file =="
xcrun llvm-cov show "$bin" -instr-profile "$prof" "$file" 2>/dev/null \
  | grep -E '^\s*[0-9]+\|\s*0\|' || echo "  (no fully-uncovered lines — remaining gaps are partial regions/branches)"

echo
echo "== uncovered REGIONS (branch arms) in $file =="
xcrun llvm-cov show "$bin" -instr-profile "$prof" "$file" --show-regions 2>/dev/null \
  | grep -B1 -E '^\s+\^0' | grep -vE '^\s+\^0|^--' | sed 's/^/  /' | head -60 || true
