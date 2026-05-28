# Ouro Workbench Roadmap

This is the product plan for making Ouro Workbench feel like a native,
agent-aware terminal workbench rather than a launcher with terminal panes.

## Immediate Terminal Feel

- Open to a real terminal session by default.
- Keep a persistent `Local Shell` terminal as the first default tab.
- Auto-start the local shell on app launch when no other session is running or
  recovering.
- Show a terminal-shaped inactive surface for stopped sessions, not an empty
  settings pane.
- Make launch/restart/recover actions visually obvious in the session header.
- Preserve native terminal focus, selection, copy/paste, and keyboard behavior.

## Session Model

- Treat local shells, named coding agents, custom terminal/TUI agents, and
  ordinary commands as first-class sessions.
- Add edit, duplicate, archive, and delete controls for custom sessions.
- Store per-session working directory, trust, auto-resume, command launch
  profile, and notes. Initial fields and custom-session management exist.
- Add session grouping by project/workspace. Initial cmux-style groups exist.
- Persist selected group and selected terminal. Initial persistence exists.
- Persist window size and sidebar width.

## Layout

- Support multiple terminal tabs per group. Initial group-scoped terminal tabs
  exist.
- Add split panes for multiple live terminals.
- Keep the boss pane collapsible so terminal work can claim the vertical space.
- Support drag-to-reorder sessions.
- Add keyboard shortcuts for new session, launch/restart, stop, focus terminal,
  redraw, next/previous session, and boss check-in.
- Add a compact command palette. Native palette now covers boss asks, refreshes,
  diagnostics, Workbench MCP, release checks, and selected-terminal controls.
- Keep dense native layout; avoid web-app dashboard sprawl.

## History And Search

- Keep the live terminal pane faithful to terminal control sequences such as
  `clear`; durable history belongs in transcripts, not backing `screen`
  scrollback.
- Persist transcript files per run.
- Show transcript tails for inactive/recovered sessions.
- Add transcript search by session and workspace. Initial workspace-wide search
  exists in native UI and MCP.
- Add filters for running, waiting, blocked, needs recovery, and recently active.
- Expose transcript search through the Workbench MCP bridge. Initial MCP tool
  exists.

## Recovery

- Continue classifying restart state as resumed, respawned, manual action, or no
  action.
- Extract native session ids for Claude Code and Codex when available.
- Verify GitHub Copilot CLI native resume behavior or keep checkpoint respawn
  explicit.
- Preserve terminal pane layout across restart.
- Add a recovery drill command/test that simulates prior running sessions.
  Initial native and MCP drill exists.
- Surface failed recovery attempts as clear obligations for the boss.

## Boss Agent

- Register the packaged `OuroWorkbenchMCP` with the selected Ouro boss agent.
  Initial native install/update status exists for `agent.json` registration.
- Let the boss inspect status, transcript tails, and queued actions from its own
  tool surface. Initial MCP tools exist for status, transcript tails,
  transcript search, recovery drill, and queued control/organization actions.
- Keep native check-ins for human-facing status.
- Keep action execution trust-gated and auditable.
- Add an action log view with source, requested action, result, and timestamp.
  Initial persisted log and dashboard view exist for boss/external actions.
- Add boss watch mode for periodic status checks. Initial mode exists and
  persists across app launches.
- Add "what changed since last check-in" summaries. Initial summaries exist.

## Ouro Agent Management

- Treat local Ouro agents as first-class Workbench entities, discovered from
  `~/AgentBundles/*.ouro`. Initial native inventory exists in the boss pane.
- Allow the human to choose any discovered local Ouro agent as the Workbench
  boss. Initial boss switching is wired to the native agent manager and header
  selector.
- Show agent bundle health: missing config, invalid config, disabled config,
  and provider/model lane summaries. Initial health exists.
- Register or update Workbench MCP for any discovered local agent, not only the
  current boss. Initial per-agent MCP action exists.
- Open managed terminals for conversational `ouro hatch` and remote-bundle
  `ouro clone` so agent creation/auth prompts stay visible, recoverable, and
  transcripted. Initial install sheet exists.
- Add full provisioning flows for remote catalogs, templates, vault readiness,
  and agent bundle sync once the Ouro CLI exposes stable noninteractive
  contracts for them.

## Agent CLI Identity

- Detect Claude Code, GitHub Copilot CLI, and OpenAI Codex from launched
  terminal commands instead of using fixed app modes. Initial command detection
  exists.
- Detect missing CLIs and show clear install/auth status.
  Initial executable health exists for detected terminal commands.
- Add preset editors for launch arguments.
- Add yolo/dangerous-mode profile visibility without burying it in docs.
  Initial trust/restart chips exist in the session header and TTFA popover.
- Add per-tab health checks.
  Initial executable health exists for configured and detected session commands.
- Add default recovery prompts for agents without native resume.

## Integrations

- Wire Workbench MCP into Ouro agent setup.
  Initial native registration for the selected boss exists.
- Add optional MCP setup snippets for Claude Code, Codex, and other tools.
- Surface Git branch, PR, CI, and dirty-worktree status per session. Initial
  per-session branch, dirty-tree, and ahead/behind status exists in the native
  sidebar (read-only, lock-free `git` probe with a watchdog) and is reported to
  the boss via the check-in prompt and the `workbench_status` MCP tool. PR/CI
  status is still pending.
- Add hooks for task docs and Desk summaries.
- Keep Mailbox as read plane and Workbench MCP as local control/status plane.

## Safety And Audit

- Keep all boss/external actions trust-gated.
- Add a durable action log.
  Initial persisted, bounded action log exists.
- Add explicit "untrusted" visual state and blocked action explanations.
  Initial trust chips and skipped action log entries exist.
- Add a way to downgrade a session to untrusted.
  Initial edit-session and boss action support exists.
- Keep transcript reads bounded by default and capped for external tools.
- Never claim a process survived reboot; preserve recovery truth.

## Native Release

- Add app icon and bundle assets.
  Initial deterministic icon generation and bundle verification exists.
- Add signing and notarization.
- Add versioned release artifacts.
  Initial verified zip/manifest artifacts and GitHub Release workflow exist.
- Add update/install story.
  Initial protected-artifact installer, release installer, and in-app release
  checker exist.
- Add basic UI automation or screenshot checks for the native app.
  Initial native scenario renderer covers 25,000 PR passes and 100,000 scheduled
  deep passes.
- Keep branch protection and CI green on `main`.

## Current Thin Slice

Make Workbench open like a terminal:

- Add a default `Local Shell` session.
- Select it first.
- Auto-start it on app launch when nothing else is running.
- Show inactive sessions in a terminal-shaped surface.
- Keep existing terminal tabs and boss controls intact while migrating away from
  fixed named agent tabs.
