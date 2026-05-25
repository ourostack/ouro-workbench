# Surface Audit

Last audited: 2026-05-24.

## Scope

This audit covers the native macOS app, cmux-style group/sidebar organization,
arbitrary terminal tabs, detected terminal-agent identities, restart recovery,
transcript surfaces, boss-agent MCP control, launch-at-login packaging, tests,
and user-facing docs.

## Findings Fixed

- Header chrome overlap: fixed in the prior header pass by keeping boss controls
  in the detail header and leaving the sidebar titlebar area clear.
- GitHub Copilot CLI command shape: detected Copilot terminals launch through
  the GitHub CLI bridge as `gh copilot`, with trusted mode passing `--yolo`
  after the `gh` argument boundary. Existing persisted generated entries are
  migrated on bootstrap so stale `copilot --yolo` commands do not survive.
- Dashboard crowding: metrics, Needs Me, Coding, action-log, and session-status
  rows now use adaptive/truncated layouts instead of relying on single rigid
  horizontal rows.
- MCP action validation: `workbench_request_action` now rejects empty
  `sendInput` requests before enqueueing them, matching the native app's action
  execution guard.
- Transcript readability: transcript search results and inactive-session tails
  now strip terminal ANSI escape/control sequences before rendering in native UI
  or returning through MCP.
- Transcript search lifecycle: editing or clearing the query clears stale
  results, so the dashboard never shows old matches under a new or empty query.
- Fixed-tab product model: replaced hard-coded Claude/Copilot/Codex top-level
  tabs with group-scoped terminals whose CLI identity is detected from command
  shape.
- Legacy scaffold cleanup: untouched generated Copilot/Codex/Demo terminals are
  removed on bootstrap, while terminals with real run history stay as ordinary
  user-owned tabs.
- Claude restart smoke failure: Workbench-launched terminals now include
  `$HOME/.local/bin` in PATH, so `/usr/bin/env claude` resolves the same CLI the
  user's shell can run.
- Boss-pane crowding: the coordination pane can be collapsed without disabling
  Boss Watch, giving direct terminal work the vertical space it needs.
- Boss organization blindness: prompts and MCP status include selected group,
  all groups, active terminal names, and each process's group/CLI identity.
- TUI repaint readability: inactive transcript display now omits dense cursor
  repaint fragments instead of showing vertical character noise.

## Verified Surfaces

- Native layout: sidebar, header, boss dashboard, session detail, inactive
  terminal surface, custom-session controls, command palette, transcript search,
  recovery drill, Workbench MCP setup, and launch-at-login status.
- Terminal tabs: local shell, detected Claude Code, detected GitHub Copilot CLI,
  detected OpenAI Codex, and arbitrary shell-wrapped custom sessions inside
  named groups.
- Recovery: startup reconciliation, native resume commands, checkpoint respawn,
  manual-recovery classification, and non-mutating recovery drill.
- Boss control: status prompt, transcript tail/search, recovery drill, queued
  launch/recover/terminate/sendInput, trust/archive gates, and action log.
- Packaging: release app bundle includes both `OuroWorkbench` and
  `OuroWorkbenchMCP`.

## Verification Commands

```bash
git diff --check
swift build
swift test
scripts/install-app.sh --open
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | "/Users/arimendelow/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP"
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"workbench_status","arguments":{}}}' | "/Users/arimendelow/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP"
```

Expected smoke result:

```text
118 tests pass; installed app shows group-scoped Local Shell + used terminals
only; packaged MCP returns tool definitions and group-aware status.
```
