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
   - System `screen` sessions as the process persistence layer.
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

4. Ouro agent management
   - Discovers local agents from `~/AgentBundles/*.ouro`.
   - Reads `agent.json` enough to show ready/disabled/missing/invalid config
     posture and provider/model lanes.
   - Lets Workbench select an installed local Ouro agent as boss and register
     the packaged Workbench MCP server for any discovered bundle.
   - Opens conversational `ouro hatch` and remote-bundle `ouro clone` as
     managed terminal sessions so agent installation remains visible,
     interactive, and recoverable.

5. Terminal-agent tabs
   - Local Shell.
   - Claude Code, when a tab command resolves to `claude`.
   - GitHub Copilot CLI, when a tab command resolves to `gh copilot`.
   - OpenAI Codex, when a tab command resolves to `codex`.
   - Custom terminal/TUI agents created from native `New Terminal`.

## Terminal Process Model

The visible terminal is a client, not the durable process owner:

```text
SwiftTerm view -> screen attach client -> stable screen session -> shell/TUI/agent
```

Each Workbench terminal id maps to one deterministic `screen` session name. A
normal launch uses `screen -D -RR -S <name> -- <command>`, which creates the
session the first time and reattaches to it later. App quit, app force-quit, and
app reinstall detach the client while the session keeps running. Manual `Stop`
uses `screen -S <name> -X quit`, making the operator's stop action the only
Workbench path that intentionally ends the underlying terminal session.

Release app bundles carry their own persistence backend at
`Contents/MacOS/Tools/screen`. Development runs fall back to `/usr/bin/screen`
when the bundled tool is unavailable.

`screen` is configured with UTF-8, xterm-compatible terminal capabilities, zero
backing scrollback, and a non-Ctrl-A command escape so shells and terminal agents
continue to feel like ordinary terminals. Durable output history belongs to
Workbench transcripts; keeping `screen` scrollback at zero prevents commands
such as `clear` from re-exposing old output when the native pane is resized or
reattached.

## Persistence Contract

The app must never pretend a process survived a computer restart. It preserves
live processes across app death through `screen`, and persists enough state to
recover honestly after machine reboot:

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
