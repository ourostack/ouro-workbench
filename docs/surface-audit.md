# Surface Audit

Last audited: 2026-05-25.

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
- Generated scaffold cleanup: untouched generated Copilot/Codex/Demo terminals are
  removed on bootstrap, while terminals with real run history stay as ordinary
  user-owned tabs.
- Claude restart smoke failure: Workbench-launched terminals now include
  `$HOME/.local/bin` in PATH, so `/usr/bin/env claude` resolves the same CLI the
  user's shell can run.
- Boss-pane crowding: the coordination pane can be collapsed without disabling
  Boss Watch, giving direct terminal work the vertical space it needs.
- Boss dashboard clipping: metrics now render as compact top-of-pane chips, the
  action log is compact by default, and dashboard warning banners are styled and
  placed before lower diagnostic surfaces so short windows do not slice text at
  the terminal split boundary.
- Terminal focus chrome: focus mode reserves the native macOS traffic-light
  region for both terminal content and floating controls, preventing terminal
  text from rendering under the window buttons.
- Scenario surface contract: the 5000-case scenario matrix now verifies native
  surface chrome invariants in addition to recovery, readiness, and command
  planning outcomes.
- Native scenario renderer: `OuroWorkbenchScenarioVerifier` renders all 5000
  matrix rows through standard, compact, short, tall, and wide native AppKit
  surfaces, producing 25,000 layout/invariant passes and optional PNG evidence.
- Scheduled deep verifier: a separate GitHub Actions workflow runs the same
  canonical matrix plus 15,000 seeded fixture mutations for 100,000 native
  layout/invariant passes.
- Verifier evidence fingerprint: `summary.json` records coverage distributions
  and a stable digest so local, PR, and scheduled runs can be compared.
- Boss organization blindness: prompts and MCP status include selected group,
  all groups, active terminal names, and each process's group/CLI identity.
- TUI repaint readability: inactive transcript display now omits dense cursor
  repaint fragments instead of showing vertical character noise.
- Release packaging gap: app bundles now include a deterministic native icon,
  and bundle verification fails when the icon is missing.
- Unsigned preview release path: GitHub Release workflow, release notes
  generation, release installer, and native release-check row now exist.
- Boss control gap: queued Workbench actions now cover workspace organization
  as well as terminal I/O, including create group/terminal, move stopped
  sessions, trust/restart posture changes, archive, and restore.

## Verified Surfaces

- Native layout: sidebar, header, boss dashboard, session detail, inactive
  terminal surface, custom-session controls, command palette, transcript search,
  recovery drill, Workbench MCP setup, and launch-at-login status.
- Terminal tabs: local shell, detected Claude Code, detected GitHub Copilot CLI,
  detected OpenAI Codex, and arbitrary shell-wrapped custom sessions inside
  named workspaces.
- Recovery: startup reconciliation, native resume commands, checkpoint respawn,
  manual-recovery classification, and non-mutating recovery drill.
- Boss control: status prompt, transcript tail/search, recovery drill, queued
  launch/recover/terminate/sendInput, trust/archive gates, and action log.
- Packaging: release app bundle includes `OuroWorkbench`, `OuroWorkbenchMCP`,
  bundled `screen`, SwiftTerm resources, and the native app icon.

## Verification Commands

```bash
git diff --check
swift build
swift test
swift run OuroWorkbenchScenarioVerifier --out .build/workbench-scenario-verifier --no-samples
swift run OuroWorkbenchScenarioVerifier --out .build/workbench-scenario-verifier-deep --no-samples --deep-scenarios 15000 --seed 20260525
scripts/install-app.sh --open
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | "/Users/arimendelow/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP"
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"workbench_status","arguments":{}}}' | "/Users/arimendelow/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP"
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"workbench_request_action","arguments":{"action":"sendInput","entry":"<process-id>","text":"printf '\''BEFORE_CLEAR\\n'\''; clear; printf '\''AFTER_CLEAR\\n'\''","appendNewline":true,"source":"surface-audit-clear-smoke"}}}' | "/Users/arimendelow/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP"
```

Expected smoke result:

```text
156 tests pass; 5000 scenario rows render through 25,000 native verifier passes
with zero failures and coverage digest `567dc7ec0c45835b`; deep sweep renders
20,000 rows through 100,000 verifier passes with zero failures and coverage
digest `0fd57795f807596d`; installed app shows only user-created/imported
sessions; packaged MCP returns tool definitions and workspace-aware status;
dashboard text is not clipped; focus mode terminal text stays below the macOS
traffic lights; clear repaints the visible terminal to AFTER_CLEAR plus a fresh
prompt and old output does not return after leaving focus mode.
```
