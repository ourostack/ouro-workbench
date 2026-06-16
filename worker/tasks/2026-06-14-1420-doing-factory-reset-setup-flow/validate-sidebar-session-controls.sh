#!/usr/bin/env bash
set -euo pipefail

ART="worker/tasks/2026-06-14-1420-doing-factory-reset-setup-flow"
APP="$HOME/Applications/Ouro Workbench.app"
TEST_SUPPORT="$PWD/$ART/live-sidebar-support"
rm -rf "$TEST_SUPPORT"
mkdir -p "$TEST_SUPPORT"
"$APP/Contents/MacOS/OuroWorkbench" --write-e2e-state sidebar-session-controls "$TEST_SUPPORT/workspace-state.json" > "$ART/sidebar-fixture.log" 2>&1
"$APP/Contents/MacOS/OuroWorkbench" --app-support-root "$TEST_SUPPORT" --auto-launch-resumable-for-e2e > "$ART/e2e-sidebar-app.log" 2>&1 &
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
screencapture -x "$ART/e2e-sidebar-session-controls.png"
plutil -p "$TEST_SUPPORT/workspace-state.json" > "$ART/e2e-sidebar-state.txt"
grep -F 'Fixture Workspace' "$TEST_SUPPORT/workspace-state.json"
grep -F 'Fixture Running Session' "$TEST_SUPPORT/workspace-state.json"
if rg -n 'Section\("Groups"\)|New Group|Move to Group|Delete Terminal Group|Groups with terminals|New Terminal Group|Edit Terminal Group|Move this session to another group' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift; then
  exit 1
fi
rg -n 'Section\(WorkbenchSurfacePolicy\.workspaceSectionTitle\)' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift
rg -n 'Section\(WorkbenchSurfacePolicy\.bossSectionTitle\)' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift
rg -n 'WorkbenchSurfacePolicy\.shouldShowRecovery\(recoverableCount: model\.recoverableEntries\.count\)' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift
rg -n 'RunningSessionHeaderControls\(entry: entry, model: model\)' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift
rg -n 'Session Controls' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift
rg -n 'Label\("Stop", systemImage: "stop.fill"\)' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift
rg -n 'Label\("Recover", systemImage: "arrow.clockwise.circle"\)' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift
rg -n 'Label\("Launch", systemImage: "play.fill"\)' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift
test -s "$ART/e2e-sidebar-session-controls.png"
{
  printf 'PASS sidebar_session_controls\n'
  printf 'frontmost_pid=%s\n' "$FRONT_PID"
  printf 'state_path=%s\n' "$TEST_SUPPORT/workspace-state.json"
  printf 'screenshot=%s\n' "$ART/e2e-sidebar-session-controls.png"
  printf 'assertion=Workspaces section wired through policy\n'
  printf 'assertion=Boss section wired through policy\n'
  printf 'assertion=healthy recovery hidden by empty recoverable entries\n'
  printf 'assertion=Stop primary action wired in source\n'
  printf 'assertion=Session Controls menu wired in source\n'
  printf 'assertion=Launch/Recover inactive policies wired in source\n'
} > "$ART/e2e-sidebar-session-controls.md"
grep -F 'PASS sidebar_session_controls' "$ART/e2e-sidebar-session-controls.md"
kill "$PID" >/dev/null 2>&1 || true
wait "$PID" >/dev/null 2>&1 || true
trap - EXIT
