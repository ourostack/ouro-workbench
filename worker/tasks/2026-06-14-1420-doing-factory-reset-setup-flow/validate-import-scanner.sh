#!/usr/bin/env bash
set -euo pipefail

ART="worker/tasks/2026-06-14-1420-doing-factory-reset-setup-flow"
APP="$HOME/Applications/Ouro Workbench.app"
SCAN_HOME="$PWD/$ART/live-scan-home"
rm -rf "$SCAN_HOME"
mkdir -p "$SCAN_HOME/.codex/archived_sessions" "$SCAN_HOME/.codex/manual-recovery-20260614" "$SCAN_HOME/.claude/tasks" "$SCAN_HOME/.claude/projects/-Users-arimendelow-Projects-fixture"
NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf '{"id":"codex-archive-live","timestamp":"%s","cwd":"/Users/arimendelow/Projects/fixture","prompt":"continue fixture archive"}\n' "$NOW" > "$SCAN_HOME/.codex/archived_sessions/session.jsonl"
printf '{"id":"codex-manual-live","timestamp":"%s","cwd":"/Users/arimendelow/Projects/fixture","prompt":"manual recovery fixture"}\n' "$NOW" > "$SCAN_HOME/.codex/manual-recovery-20260614/recovery.jsonl"
printf '{"sessionId":"claude-task-live","updatedAt":"%s","cwd":"/Users/arimendelow/Projects/fixture","summary":"Claude task fixture"}\n' "$NOW" > "$SCAN_HOME/.claude/tasks/task.json"
printf '{"sessionId":"claude-project-live","updatedAt":"%s","cwd":"/Users/arimendelow/Projects/fixture","summary":"Claude project fixture"}\n' "$NOW" > "$SCAN_HOME/.claude/projects/-Users-arimendelow-Projects-fixture/session.json"
"$APP/Contents/MacOS/OuroWorkbench" --dump-recent-sessions-json --scan-home-root "$SCAN_HOME" > "$ART/e2e-import-scanner.json"
jq -e '[.[] | select(.source == "openAICodex") | select((.evidencePaths // []) | map(test("/\\.codex/(archived_sessions|manual-recovery-)")) | any)] | length >= 1' "$ART/e2e-import-scanner.json"
jq -e '[.[] | select(.source == "claudeCode") | select((.evidencePaths // []) | map(test("/\\.claude/(tasks|projects)")) | any)] | length >= 1' "$ART/e2e-import-scanner.json"
jq -e '[.[] | select((.resumeCommand // []) | length > 0) | select((.evidencePaths // []) | length > 0)] | length >= 2' "$ART/e2e-import-scanner.json"
jq -r '.[] | [.source, .title, .workingDirectory, (.resumeCommand | join(" ")), (.evidencePaths | join(","))] | @tsv' "$ART/e2e-import-scanner.json" > "$ART/e2e-import-scanner.tsv"
{
  printf 'PASS import_scanner\n'
  printf 'scan_home=%s\n' "$SCAN_HOME"
  printf 'json=%s\n' "$ART/e2e-import-scanner.json"
  printf 'tsv=%s\n' "$ART/e2e-import-scanner.tsv"
  printf 'assertion=synthetic Codex archived/manual-recovery source detected\n'
  printf 'assertion=synthetic Claude tasks/projects source detected\n'
  printf 'assertion=evidence paths and resume commands present\n'
} > "$ART/e2e-import-scanner.md"
grep -F 'PASS import_scanner' "$ART/e2e-import-scanner.md"
