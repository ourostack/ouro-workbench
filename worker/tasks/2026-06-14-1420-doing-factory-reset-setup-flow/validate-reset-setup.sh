#!/usr/bin/env bash
set -euo pipefail

ART="worker/tasks/2026-06-14-1420-doing-factory-reset-setup-flow"
APP="$HOME/Applications/Ouro Workbench.app"
TEST_SUPPORT="$PWD/$ART/live-reset-support"
rm -rf "$TEST_SUPPORT"
mkdir -p "$TEST_SUPPORT"
printf '{"projects":[{"name":"This Mac"}],"processEntries":[{"name":"Local Shell"}]}\n' > "$TEST_SUPPORT/workspace-state.json"
printf 'stale-before-reset\n' > "$TEST_SUPPORT/force-first-run-setup"
"$APP/Contents/MacOS/OuroWorkbench" --app-support-root "$TEST_SUPPORT" --factory-reset-for-e2e > "$ART/e2e-reset-command.log" 2>&1
test -e "$TEST_SUPPORT/force-first-run-setup"
! grep -F 'stale-before-reset' "$TEST_SUPPORT/force-first-run-setup"
ls "$TEST_SUPPORT"/workspace-state.*.bak.json > "$ART/e2e-reset-backups.txt"
"$APP/Contents/MacOS/OuroWorkbench" --app-support-root "$TEST_SUPPORT" > "$ART/e2e-reset-app.log" 2>&1 &
PID=$!
trap 'kill "$PID" >/dev/null 2>&1 || true; wait "$PID" >/dev/null 2>&1 || true' EXIT
sleep 6
FRONT_PID=""
for _ in {1..20}; do
  osascript -e "tell application \"System Events\" to set frontmost of first application process whose unix id is $PID to true" >/dev/null 2>&1 || true
  FRONT_PID="$(osascript -e 'tell application "System Events" to unix id of first application process whose frontmost is true' 2>/dev/null || true)"
  if [ "$FRONT_PID" = "$PID" ]; then
    break
  fi
  sleep 0.5
done
test "$FRONT_PID" = "$PID"
screencapture -x "$ART/e2e-reset-setup.png"
STATE="$TEST_SUPPORT/workspace-state.json"
test -f "$STATE"
plutil -p "$STATE" > "$ART/e2e-reset-state.txt"
! grep -F 'Local Shell' "$STATE"
! test -e "$TEST_SUPPORT/force-first-run-setup"
test -s "$ART/e2e-reset-setup.png"
{
  printf 'PASS reset_setup\n'
  printf 'frontmost_pid=%s\n' "$FRONT_PID"
  printf 'state_path=%s\n' "$STATE"
  printf 'screenshot=%s\n' "$ART/e2e-reset-setup.png"
  printf 'assertion=marker consumed\n'
  printf 'assertion=no Local Shell in setup workspace\n'
  printf 'assertion=onboarding/setup screenshot captured from launched app\n'
} > "$ART/e2e-reset-setup.md"
grep -F 'PASS reset_setup' "$ART/e2e-reset-setup.md"
kill "$PID" >/dev/null 2>&1 || true
wait "$PID" >/dev/null 2>&1 || true
trap - EXIT
