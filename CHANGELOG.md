# Changelog

## 0.1.19 - First-class Agents pane

- Added an `Agents` sidebar section above `Groups` listing every Ouro bundle in `~/AgentBundles/*.ouro`. Each row shows the bundle name, a status dot (ready / disabled / missing config / invalid config), the current boss flag, and the human-facing provider/model lane summary. Selecting an agent opens a dedicated detail pane — orthogonal to terminal selection — without diving into the boss dashboard's Advanced disclosure.
- Built a dedicated `AgentDetailView` with the same chrome philosophy as `SessionDetailView`: a slim title strip (status dot, name, boss pill, More menu, `Use as Boss` primary action) with everything else in body cards. A disclosure inspector reveals the bundle path, config path, status detail, and MCP registration detail.
- Surfaced model providers per agent: the Lanes card shows the human-facing and agent-facing provider/model pairs as read from `agent.json`, with an `Edit agent.json` button that opens the file in the user's default JSON editor.
- Surfaced repair as a first-class action: `Run ouro check` opens a Workbench terminal pre-loaded with `ouro check --agent <name>` so providers, the daemon, and MCP tools can be fixed without leaving the app or remembering the CLI shape.
- Surfaced Workbench MCP install/update directly from the agent's status card (no more digging into Boss Dashboard → Advanced → Ouro Agents).
- Extended the `Boss:` selector menu with `Manage Agents…` and `Hatch / Clone Agent…` entries so the new pane and the hatching flow are reachable from the always-visible header chip.
- When the sidebar's `Agents` section is empty, it shows `Hatch Your First Agent` as a primary entry; once at least one bundle exists, the entry becomes `Hatch / Clone Agent`.
- Selecting a terminal automatically clears the Agents pane focus (and vice versa), so the detail pane is always exactly one of: agent, terminal, or the Agent Home empty state.

## 0.1.18 - Install over /Applications no longer feels damaged

- Refresh Launch Services and clear `com.apple.quarantine` xattrs at the end of `scripts/install-app.sh` so replacing an ad-hoc-signed `Ouro Workbench.app` in place (especially under `/Applications`) no longer surfaces the generic "the application may be damaged or incomplete" Finder error. Without the refresh, Launch Services held the previous bundle signature for that path and would not let Finder open the new build.

## 0.1.17 - Terminal-First Workbench

- Slimmed the app chrome dramatically so the terminal owns the screen: the top header drops to a single ~40pt row, the boss dashboard defaults to collapsed (with a one-time migration for existing installs), and the per-session chrome is now a single 38pt title strip with a status dot, the terminal name, and a compact action cluster.
- Folded the old multi-row session header — pills, resume command, notes, transcript, Edit/Duplicate/Move/Archive/Delete — into a disclosure-driven inspector and a single overflow menu, so they remain one click away without ever eating vertical space.
- Made onboarding import-proposal rows actually selectable: tap a row to toggle whether that terminal participates in Arrange, with a per-group select-all toggle and live counts. The Arrange button is disabled and explains itself when zero terminals are selected.
- Arrange now reports what it did: it dismisses the onboarding sheet on success and shows a transient banner ("Arranged N terminals across M groups") with a one-click "Open" jump to the first imported terminal.
- Replaced the empty "No session selected" placeholder with an Agent Home surface that surfaces Hatch / Set Up Workbench / New Terminal as first-class actions and lists installed agents with the active boss flagged.
- Replaced the fragmented inactive-session view (transcript snippets + embedded mini-terminal box) with a calm single card showing status, recovery reason, the launch command, and a single primary action; transcripts moved to a focused sheet.
- Trimmed the boss dashboard so it shows only essentials (metrics, mailbox warnings, Boss Line, latest reply, needs-me / coding counts) by default; agent manager, transcript search, runtime, release, recovery drill, MCP setup, full action log, and applied actions live behind an Advanced disclosure.
- Reorganized the top toolbar so Watch, Set Up Workbench, Refresh, and Hatch live in a single "More" menu; the visible row is now Boss · status · autonomy · dashboard chevron · More · Commands · Check In.

## 0.1.16 - Onboarding Setup Assistant

- Replaced the ambiguous onboarding free-form prompt with a visible Setup Assistant that explains whether it is asking the selected boss or running a setup step.
- Show setup-action status and boss replies inside onboarding instead of sending answers only to the main Boss Line surface.
- Keep typed scan/import requests behind the same provider and Workbench-tool readiness gates as the primary onboarding buttons.
- Treat natural-language questions such as "which sessions should I import?" as boss questions instead of accidentally applying an import command.

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
