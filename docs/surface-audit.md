# Surface Audit

Last audited: 2026-05-23.

## Scope

This audit covers the native macOS app, built-in terminal-agent lanes, arbitrary
custom sessions, restart recovery, transcript surfaces, boss-agent MCP control,
launch-at-login packaging, tests, and user-facing docs.

## Findings Fixed

- Header chrome overlap: fixed in the prior header pass by keeping boss controls
  in the detail header and leaving the sidebar titlebar area clear.
- GitHub Copilot CLI lane: the lane now launches through the GitHub CLI bridge
  as `gh copilot`, with trusted mode passing `--yolo` after the `gh` argument
  boundary. Existing persisted P0 lanes are repaired on bootstrap so stale
  `copilot --yolo` entries do not survive.
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

## Verified Surfaces

- Native layout: sidebar, header, boss dashboard, session detail, inactive
  terminal surface, custom-session controls, command palette, transcript search,
  recovery drill, Workbench MCP setup, and launch-at-login status.
- Terminal lanes: local shell, Claude Code, GitHub Copilot CLI, OpenAI Codex,
  and arbitrary shell-wrapped custom sessions.
- Recovery: startup reconciliation, native resume commands, checkpoint respawn,
  manual-recovery classification, and non-mutating recovery drill.
- Boss control: status prompt, transcript tail/search, recovery drill, queued
  launch/recover/terminate/sendInput, trust/archive gates, and action log.
- Packaging: release app bundle includes both `OuroWorkbench` and
  `OuroWorkbenchMCP`.

## Verification Commands

```bash
swift test
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"workbench_request_action","arguments":{"action":"sendInput","entry":"Claude Code"}}}' | .build/debug/OuroWorkbenchMCP
```

Expected MCP smoke result:

```text
sendInput requires non-empty text
```
