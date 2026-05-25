# Ouro Workbench Architecture

Ouro Workbench is a native macOS workbench for terminal/TUI agents and local
developer processes.

## Core Product Shape

- Native app first.
- Terminal/TUI agents and local shells are first-class terminal tabs.
- Groups are first-class project/workstream scopes in the sidebar.
- Claude Code, GitHub Copilot CLI, and OpenAI Codex are detected from terminal
  commands instead of being fixed top-level app modes.
- A selectable Ouro boss agent can observe and control the organized workspace.
- Restart recovery is P0: sessions restore, resume, respawn, or report manual
  action truthfully after reboot.

## Runtime Layers

1. Native macOS shell
   - SwiftUI/AppKit UI.
   - SwiftTerm terminal panes.
   - No web-first terminal surface.

2. Workbench core
   - Workspace/project group records.
   - Selected group and selected terminal persistence.
   - Terminal-agent presets.
   - Process entries and run history.
   - Terminal command identity detection.
   - Recovery planning.
   - Persistent JSON state, transcript files, queued action requests, and a
     bounded action log.

3. Boss-agent bridge
   - Lets the selected Ouro agent inspect state and act.
   - Provides tools for status, transcript tail/search, queued process control,
     input sending, and recovery drill summaries.
   - Uses Ouro Mailbox HTTP as the read plane and `ouro mcp-serve --agent <agent>`
     as the boss conversation plane before adding new daemon APIs.

4. Terminal-agent tabs
   - Local Shell.
   - Claude Code, when a tab command resolves to `claude`.
   - GitHub Copilot CLI, when a tab command resolves to `gh copilot`.
   - OpenAI Codex, when a tab command resolves to `codex`.
   - Custom terminal/TUI agents created from native `New Terminal`.

## Persistence Contract

The app must never pretend a process survived a computer restart. Instead it
persists enough state to recover honestly:

- project and process definitions
- selected group and selected terminal
- detected terminal-agent kind and command line
- cwd and trust status
- latest run metadata
- transcript/output pointers
- terminal session ids where available
- recovery policy and attention state
- Boss Watch preference
- bounded boss/external action log

On startup, recovery classifies prior sessions as:

- `autoResume`: native session metadata exists and policy allows resume
- `respawn`: trusted process or custom terminal/TUI session can reopen from
  persisted command and workspace context
- `manualActionNeeded`: human/boss review is required
- `noAction`: auto-resume is disabled

## Repository Boundary

This repo owns the native workbench. Ouroboros Agent Harness remains the local
agent runtime. Hosted substrate work remains outside this repo.

See [ouro-bridge.md](ouro-bridge.md) for the current bridge contract.
