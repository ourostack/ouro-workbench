#!/usr/bin/env bash
# Regression guard for Slice ① — kill per-tab cost badges.
#
# App-target has no XCTest seam (it's a SwiftUI executable), so this shell
# assertion is the truthful "failing-test-first" equivalent for a no-logic,
# view-only deletion. See the doing doc's TDD Requirements section.
#
# RED  (pre-removal): the spend tokens are present -> exits 1.
# GREEN (post-removal): spend tokens absent AND kept surfaces present -> exits 0.
#
# Usage: ./guard-no-cost-badge.sh   (run from repo root)

set -uo pipefail

SRC="Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift"

if [[ ! -f "$SRC" ]]; then
    echo "GUARD ERROR: source not found: $SRC (run from repo root)" >&2
    exit 2
fi

fail=0

# --- NEGATIVE checks: these spend tokens MUST be ABSENT ---------------------
# Each must NOT match. If it matches, the spend surface is still present (RED).
assert_absent() {
    local label="$1"; shift
    local pattern="$1"; shift
    if grep -qF -- "$pattern" "$SRC"; then
        echo "FAIL (present, expected absent): $label  ->  $pattern" >&2
        fail=1
    else
        echo "ok (absent): $label"
    fi
}

# --- POSITIVE checks: kept surfaces MUST still be PRESENT --------------------
# Narrow checks so a later refactor can't silently strip health/todo.
assert_present() {
    local label="$1"; shift
    local pattern="$1"; shift
    if grep -qF -- "$pattern" "$SRC"; then
        echo "ok (present): $label"
    else
        echo "FAIL (absent, expected present): $label  ->  $pattern" >&2
        fail=1
    fi
}

echo "--- spend tokens (must be ABSENT) ---"
assert_absent "cost MetricChip render" 'MetricChip(label: "tok"'
assert_absent "cost tooltip helper"    'func tokenHelp'
assert_absent "a11y cost clause"       'about \(usd) tokens'

echo "--- kept surfaces (must be PRESENT) ---"
assert_present "health glyph"          'healthGlyph'
assert_present "todo mini"             'todoMini'
assert_present "MetricChip primitive"  'struct MetricChip: View'

echo "------------------------------------"
if [[ "$fail" -ne 0 ]]; then
    echo "GUARD: FAIL"
    exit 1
fi
echo "GUARD: PASS"
exit 0
