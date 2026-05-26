# Changelog

## 0.1.11 - Workbench Sense Registration

- Register Workbench as an explicit Ouro local sense when installing the boss-agent MCP bridge.
- Treat a matching Workbench MCP server without `senses.workbench.enabled` as repair-needed instead of fully registered.
- Preserve existing boss-agent senses while adding the Workbench sense declaration.

## 0.1.5 - Sidebar And Resize Polish

- Reworked sidebar project and add-action rows so group names stay readable and "New Group" / "New Terminal" no longer look like selected tabs.
- Redraw terminals after real host-size changes so collapsing, expanding, and focusing the boss pane does not leave prompts stranded halfway down the terminal.
- Added a small backed terminal inset so shell prompts and typed commands do not render hard against the window edge.

## 0.1.4 - Dashboard Row Polish

- Stabilized boss-dashboard status rows so long runtime, diagnostics, release, recovery, MCP, and mailbox messages truncate predictably without crowding controls.
- Kept the compact Action Log reveal control reachable when native action results are long.
- Reworked terminal hosting so split and full-screen terminals redraw cleanly after app reopen or focus-mode reparenting.

## 0.1.3 - Header Control Polish

- Compact terminal signal controls to stable icon buttons so the session header stays usable in normal-width windows without truncated labels.
- Preserve tooltips and accessibility labels for Full Screen, Redraw, Ctrl-C, Esc, EOF, and Stop controls in both pane and focused terminal modes.

## 0.1.2 - Operator Control Surface

- Expanded the command palette with boss quick asks, workspace refresh, Ouro-agent refresh, Workbench MCP install/refresh, release-page open, diagnostics reveal/copy/open-folder, and selected-terminal actions.
- Made command palette search token-aware with aliases for operator terms like `diag`, `boss`, `mcp`, `folder`, and `signal`.
- Added explicit terminal `EOF` / Ctrl-D controls, `Command-L` redraw shortcuts, selected-terminal copy/open/reveal commands, and smaller session-header utility buttons.
- Added diagnostics zip path copy, diagnostics output-folder open, action-log entries for native diagnostics/release/terminal-control actions, and stronger diagnostics runner validation.
- Hardened packaged-app preflight by smoke-running the bundled diagnostics helper and verifying the helper is non-empty.

## 0.1.1 - Post-Preview Hardening

- Added explicit terminal `Redraw` controls that send Ctrl-L in pane and focused terminal modes.
- Added command-palette actions for terminal focus, terminal redraw, boss-pane toggle, support diagnostics, and release update checks.
- Added in-app support diagnostics collection and Finder reveal from the native boss dashboard.
- Bundled the support diagnostics helper into the `.app` and made bundle verification reject missing or non-executable diagnostics helpers.
- Updated support diagnostics to run from either a repo checkout or the installed app bundle.

## 0.1.0 - Unsigned Preview

- Native macOS Workbench for Claude Code, OpenAI Codex, GitHub Copilot CLI, local shells, and arbitrary terminal/TUI agents.
- Cmux-style groups with multiple terminal tabs per group.
- Persistent terminal backing through bundled `screen` for app quit and force-quit recovery.
- Startup recovery planner for native resume, checkpoint respawn, and manual-action classification after computer restart.
- Selectable Ouro boss agent with Boss Line, Boss Watch, focused Ask Boss, and TTFA readiness.
- Packaged Workbench MCP server for status, transcript tail/search, recovery drill, and queued trusted actions.
- Versioned unsigned app artifact zip and manifest with SHA-256 verification.
- Protected CI gates for Swift tests, native scenario verification, bundle verification, artifact verification, and install rollback smoke.
