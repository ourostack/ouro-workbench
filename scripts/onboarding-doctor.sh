#!/usr/bin/env bash
#
# Headless onboarding-readiness doctor.
#
# Runs the REAL launch-time PATH capture, the REAL provider checks, the REAL readiness
# computation, and a REAL boss check-in — from a MINIMAL environment that faithfully
# reproduces a Finder launch (where the interactive-vs-non-interactive login-shell
# distinction actually bites). Prints a verdict: does the wizard advance, or which link broke.
#
# This exists because the provider-check path was historically untested and was the source of
# the multi-week "can't get past connect" onboarding failure (root cause: a non-interactive
# `-lc` PATH capture that never sourced .zshrc, so node/ouro were missing).
#
# Usage:  scripts/onboarding-doctor.sh [agent]      (default agent: ouroboros)
set -euo pipefail

AGENT="${1:-ouroboros}"

# Prefer the installed app (the real Finder-launched binary); fall back to a local debug build.
APP="$HOME/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbench"
if [ ! -x "$APP" ]; then
    APP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.build/debug/OuroWorkbench"
fi
if [ ! -x "$APP" ]; then
    echo "error: no OuroWorkbench binary found (install the app, or 'swift build' first)" >&2
    exit 1
fi

# env -i strips the calling shell's environment so the binary's own login-shell PATH capture
# is exercised exactly as it is on a Finder launch — NOT contaminated by this terminal's PATH.
exec env -i \
    HOME="$HOME" \
    USER="${USER:-$(id -un)}" \
    SHELL="${SHELL:-/bin/zsh}" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$APP" --onboarding-doctor --agent "$AGENT"
