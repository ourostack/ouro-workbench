# Ouro Workbench Roadmap

This is the product plan for making Ouro Workbench feel like a native,
agent-aware terminal workbench rather than a launcher with terminal panes.

## Immediate Terminal Feel

- Open to a real terminal session by default.
- Keep a persistent `Local Shell` session as the first lane.
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
- Store per-session working directory, trust, auto-resume, launch profile, and
  notes.
- Add session grouping by project/workspace.
- Persist selected session, window size, and sidebar width.

## Layout

- Add tabs or split panes for multiple live terminals.
- Support drag-to-reorder sessions.
- Add keyboard shortcuts for new session, launch/restart, stop, focus terminal,
  next/previous session, and boss check-in.
- Add a compact command palette.
- Keep dense native layout; avoid web-app dashboard sprawl.

## History And Search

- Keep bounded live scrollback in the terminal pane.
- Persist transcript files per run.
- Show transcript tails for inactive/recovered sessions.
- Add transcript search by session and workspace.
- Add filters for running, waiting, blocked, needs recovery, and recently active.
- Expose transcript search through the Workbench MCP bridge.

## Recovery

- Continue classifying restart state as resumed, respawned, manual action, or no
  action.
- Extract native session ids for Claude Code and Codex when available.
- Verify GitHub Copilot CLI native resume behavior or keep checkpoint respawn
  explicit.
- Preserve terminal pane layout across restart.
- Add a recovery drill command/test that simulates prior running sessions.
- Surface failed recovery attempts as clear obligations for the boss.

## Boss Agent

- Register the packaged `OuroWorkbenchMCP` with the selected Ouro boss agent.
  Initial native install/update status exists for `agent.json` registration.
- Let the boss inspect status, transcript tails, and queued actions from its own
  tool surface. Initial MCP tools exist for status, transcript tails, and queued
  launch/recover/terminate/send-input actions.
- Keep native check-ins for human-facing status.
- Keep action execution trust-gated and auditable.
- Add an action log view with source, requested action, result, and timestamp.
  Initial persisted log and dashboard view exist for boss/external actions.
- Add boss watch mode for periodic status checks.
- Add "what changed since last check-in" summaries.

## Agent Lanes

- Keep P0 lanes: Claude Code, GitHub Copilot CLI, OpenAI Codex.
- Detect missing CLIs and show clear install/auth status.
- Add preset editors for launch arguments.
- Add yolo/dangerous-mode profile visibility without burying it in docs.
- Add per-lane health checks.
- Add default recovery prompts for agents without native resume.

## Integrations

- Wire Workbench MCP into Ouro agent setup.
- Add optional MCP setup snippets for Claude Code, Codex, and other tools.
- Surface Git branch, PR, CI, and dirty-worktree status per session.
- Add hooks for task docs and Desk summaries.
- Keep Mailbox as read plane and Workbench MCP as local control/status plane.

## Safety And Audit

- Keep all boss/external actions trust-gated.
- Add a durable action log.
- Add explicit "untrusted" visual state and blocked action explanations.
- Add a way to downgrade a session to untrusted.
- Keep transcript reads bounded by default and capped for external tools.
- Never claim a process survived reboot; preserve recovery truth.

## Native Release

- Add app icon and bundle assets.
- Add signing and notarization.
- Add versioned release artifacts.
- Add update/install story.
- Add basic UI automation or screenshot checks for the native app.
- Keep branch protection and CI green on `main`.

## Current Thin Slice

Make Workbench open like a terminal:

- Add a default `Local Shell` session.
- Select it first.
- Auto-start it on app launch when nothing else is running.
- Show inactive sessions in a terminal-shaped surface.
- Keep existing named agent lanes and boss controls intact.
