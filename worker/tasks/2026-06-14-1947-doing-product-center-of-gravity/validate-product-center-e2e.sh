#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$ARTIFACT_DIR/../../.." && pwd)"
APP_BUNDLE="$HOME/Applications/Ouro Workbench.app"
APP_EXEC="$APP_BUNDLE/Contents/MacOS/OuroWorkbench"
MCP_EXEC="$APP_BUNDLE/Contents/MacOS/OuroWorkbenchMCP"
FIXTURE_DIR="$ARTIFACT_DIR/e2e-fixtures"
ROOTS_DIR="$ARTIFACT_DIR/e2e-roots"
SUMMARY="$ARTIFACT_DIR/e2e-product-center.md"
APP_PID=""

ORIGINAL_ID="22222222-2222-2222-2222-222222222222"
DELETE_ID="33333333-3333-3333-3333-333333333333"

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

append_summary() {
  printf '%s\n' "$*" >> "$SUMMARY"
}

kill_workbench() {
  if [[ -n "${APP_PID:-}" ]]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
    APP_PID=""
  fi
  pkill -x OuroWorkbench >/dev/null 2>&1 || true
  sleep 1
}

launch_app() {
  local root="$1"
  local label="$2"
  "$APP_EXEC" --app-support-root "$root" > "$ARTIFACT_DIR/${label}-app.log" 2>&1 &
  APP_PID=$!
  for _ in {1..20}; do
    if [[ -f "$root/workspace-state.json" ]] && pgrep -x OuroWorkbench >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done
  sleep 2
  raise_window
}

raise_window() {
  osascript <<'APPLESCRIPT' >/dev/null
tell application "System Events"
  tell process "OuroWorkbench"
    set frontmost to true
    perform action "AXRaise" of window 1
  end tell
end tell
APPLESCRIPT
}

window_geometry() {
  osascript <<'APPLESCRIPT'
tell application "System Events"
  tell process "OuroWorkbench"
    set frontmost to true
    perform action "AXRaise" of window 1
    set p to position of window 1
    set s to size of window 1
    return (item 1 of p as text) & " " & (item 2 of p as text) & " " & (item 1 of s as text) & " " & (item 2 of s as text)
  end tell
end tell
APPLESCRIPT
}

screenshot() {
  local label="$1"
  raise_window
  screencapture -x "$ARTIFACT_DIR/${label}.png"
}

dump_state() {
  local root="$1"
  local label="$2"
  cp "$root/workspace-state.json" "$ARTIFACT_DIR/${label}-workspace-state.json"
  plutil -p "$root/workspace-state.json" > "$ARTIFACT_DIR/${label}-state.plist.txt"
}

assert_no_local_shell_strings() {
  local state="$1"
  jq -e '([.. | strings?] | any(. == "Local Shell") | not)' "$state" >/dev/null
}

assert_empty_no_shell_state() {
  local state="$1"
  jq -e '
    .selectedEntryId == null
    and (.projects | length) == 1
    and .projects[0].name == "Unsorted Sessions"
    and (.processEntries | length) == 0
    and ((.actionLog // []) | all(.action != "launchDefaultShell" and .action != "launchAutoResumeSessionsOnStartup"))
  ' "$state" >/dev/null
  assert_no_local_shell_strings "$state"
}

mcp_request_action() {
  local root="$1"
  local label="$2"
  local action="$3"
  local entry="$4"
  printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"workbench_request_action","arguments":{"action":"%s","entry":"%s","source":"product-center-e2e","format":"json"}}}\n' "$action" "$entry" \
    | "$MCP_EXEC" --app-support-root "$root" > "$ARTIFACT_DIR/${label}-mcp-${action}.json"
  jq -e '.result.isError == false' "$ARTIFACT_DIR/${label}-mcp-${action}.json" >/dev/null
}

wait_for_jq() {
  local state="$1"
  shift
  for _ in {1..30}; do
    if jq -e "$@" "$state" >/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  jq -e "$@" "$state" >/dev/null
}

right_click_at() {
  local x="$1"
  local y="$2"
  /usr/bin/swift - "$x" "$y" <<'SWIFT'
import CoreGraphics
import Foundation

let x = Double(CommandLine.arguments[1])!
let y = Double(CommandLine.arguments[2])!
let point = CGPoint(x: x, y: y)
let source = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
usleep(80_000)
CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
SWIFT
}

flow_fresh() {
  local root="$ROOTS_DIR/fresh"
  rm -rf "$root"
  mkdir -p "$root"
  kill_workbench
  launch_app "$root" "fresh"
  screenshot "fresh-live"
  dump_state "$root" "fresh"
  assert_empty_no_shell_state "$root/workspace-state.json"
  append_summary "PASS fresh"
  append_summary "- screenshot: $ARTIFACT_DIR/fresh-live.png"
  append_summary "- state: $ARTIFACT_DIR/fresh-workspace-state.json"
  kill_workbench
}

flow_reset() {
  local root="$ROOTS_DIR/reset"
  rm -rf "$root"
  mkdir -p "$root"
  cp "$FIXTURE_DIR/stale-reset-workspace-state.json" "$root/workspace-state.json"
  kill_workbench
  launch_app "$root" "reset-before"
  screenshot "reset-before-live"
  dump_state "$root" "reset-before"
  kill_workbench
  "$APP_EXEC" --app-support-root "$root" --factory-reset-for-e2e > "$ARTIFACT_DIR/reset-command.log" 2>&1
  grep -F "factory reset ok" "$ARTIFACT_DIR/reset-command.log" >/dev/null
  [[ -f "$root/force-first-run-setup" ]] || die "reset marker was not written"
  launch_app "$root" "reset-after"
  [[ ! -f "$root/force-first-run-setup" ]] || die "reset marker was not consumed"
  screenshot "reset-after-live"
  dump_state "$root" "reset-after"
  assert_empty_no_shell_state "$root/workspace-state.json"
  append_summary "PASS reset"
  append_summary "- before screenshot: $ARTIFACT_DIR/reset-before-live.png"
  append_summary "- after screenshot: $ARTIFACT_DIR/reset-after-live.png"
  append_summary "- after state: $ARTIFACT_DIR/reset-after-workspace-state.json"
  kill_workbench
}

flow_legacy_shell() {
  local root="$ROOTS_DIR/legacy-shell"
  local sx sy sw sh
  rm -rf "$root"
  mkdir -p "$root"
  cp "$FIXTURE_DIR/legacy-shell-workspace-state.json" "$root/workspace-state.json"
  kill_workbench
  launch_app "$root" "legacy-shell"
  screenshot "legacy-shell-live"
  dump_state "$root" "legacy-shell-start"
  jq -e --arg id "$ORIGINAL_ID" '
    .processEntries[] | select(.id == $id)
    | .name == "Legacy User Shell"
      and .kind == "shell"
      and .executable == "/bin/zsh"
      and .arguments == ["-lc", "echo original"]
      and .trust == "trusted"
      and .autoResume == true
      and .workingDirectory == "/tmp"
      and .isArchived == false
  ' "$root/workspace-state.json" >/dev/null

  mcp_request_action "$root" "legacy-shell" "archive" "$DELETE_ID"
  wait_for_jq "$root/workspace-state.json" --arg id "$DELETE_ID" '.processEntries[] | select(.id == $id) | .isArchived == true'
  dump_state "$root" "legacy-shell-archived"

  mcp_request_action "$root" "legacy-shell" "restore" "$DELETE_ID"
  wait_for_jq "$root/workspace-state.json" --arg id "$DELETE_ID" '.processEntries[] | select(.id == $id) | .isArchived == false'
  dump_state "$root" "legacy-shell-restored"

  read -r sx sy sw sh <<< "$(window_geometry)"
  right_click_at "$((sx + 95))" "$((sy + 395))"
  sleep 0.5
  screenshot "legacy-shell-context-menu"
  osascript -e 'tell application "System Events" to click at {'"$((sx + 165))"', '"$((sy + 685))"'}' >/dev/null
  sleep 1
  screenshot "legacy-shell-delete-dialog"
  osascript -e 'tell application "System Events" to tell process "OuroWorkbench" to click button 1 of sheet 1 of window 1' >/dev/null
  wait_for_jq "$root/workspace-state.json" --arg original "$ORIGINAL_ID" --arg deleted "$DELETE_ID" '
    ([.processEntries[] | select(.id == $original)] | length) == 1
    and ([.processEntries[] | select(.id == $deleted)] | length) == 0
  '
  screenshot "legacy-shell-after-delete"
  dump_state "$root" "legacy-shell-after-delete"
  append_summary "PASS legacy_shell"
  append_summary "- start screenshot: $ARTIFACT_DIR/legacy-shell-live.png"
  append_summary "- context menu screenshot: $ARTIFACT_DIR/legacy-shell-context-menu.png"
  append_summary "- delete dialog screenshot: $ARTIFACT_DIR/legacy-shell-delete-dialog.png"
  append_summary "- after-delete state: $ARTIFACT_DIR/legacy-shell-after-delete-workspace-state.json"
  kill_workbench
}

flow_verify() {
  grep -F "PASS fresh" "$SUMMARY" >/dev/null
  grep -F "PASS reset" "$SUMMARY" >/dev/null
  grep -F "PASS legacy_shell" "$SUMMARY" >/dev/null
  for path in \
    "$ARTIFACT_DIR/fresh-live.png" \
    "$ARTIFACT_DIR/reset-before-live.png" \
    "$ARTIFACT_DIR/reset-after-live.png" \
    "$ARTIFACT_DIR/legacy-shell-live.png" \
    "$ARTIFACT_DIR/legacy-shell-context-menu.png" \
    "$ARTIFACT_DIR/legacy-shell-delete-dialog.png" \
    "$ARTIFACT_DIR/legacy-shell-after-delete.png" \
    "$ARTIFACT_DIR/fresh-workspace-state.json" \
    "$ARTIFACT_DIR/reset-after-workspace-state.json" \
    "$ARTIFACT_DIR/legacy-shell-after-delete-workspace-state.json"; do
    [[ -s "$path" ]] || die "missing E2E artifact: $path"
  done
  append_summary "PASS product_center_e2e"
}

main() {
  [[ -x "$APP_EXEC" ]] || die "installed app executable missing: $APP_EXEC"
  [[ -x "$MCP_EXEC" ]] || die "installed MCP executable missing: $MCP_EXEC"
  mkdir -p "$ROOTS_DIR"
  local args="$*"
  if [[ $# -eq 0 ]]; then
    set -- fresh reset legacy_shell verify
  fi
  if [[ " $args " == *" fresh "* || ! -f "$SUMMARY" ]]; then
    {
      printf '# Product Center E2E\n\n'
      printf '%s\n' "- repo: $REPO_ROOT"
      printf '%s\n' "- installed app: $APP_BUNDLE"
      printf '%s\n\n' "- started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "$SUMMARY"
  fi
  for flow in "$@"; do
    case "$flow" in
      fresh) flow_fresh ;;
      reset) flow_reset ;;
      legacy_shell) flow_legacy_shell ;;
      verify) flow_verify ;;
      *) die "unknown flow: $flow" ;;
    esac
  done
}

trap kill_workbench EXIT
main "$@"
