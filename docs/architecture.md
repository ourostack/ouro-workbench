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

## Shared Native App Shell Boundary

Workbench consumes `ouro-native-apple-app-shell` as the shared owner for
reusable Ouro native app chrome. The shell package owns common app identity,
about surfaces, command-reference presentation, release/update controls,
utility-window presentation patterns, and the validation scripts that keep those
surfaces from drifting back into app-specific code.

Workbench keeps product-specific mapping in the `OuroWorkbenchShellAdapter`
target:

- `Sources/OuroWorkbenchShellAdapter/WorkbenchShellContract.swift` declares the
  shell-facing surfaces Workbench exposes.
- `Sources/OuroWorkbenchShellAdapter/WorkbenchShellPresentation.swift` maps
  Workbench's domain catalogues, such as keyboard shortcuts, into shell UI
  presentation models.

The dependency direction is one-way:

```text
OuroWorkbenchCore -> OuroAppShellCore
OuroWorkbenchShellAdapter -> OuroWorkbenchCore + OuroAppShellContract + OuroAppShellUI
OuroWorkbenchAppViews -> OuroWorkbenchCore + OuroWorkbenchShellAdapter + OuroAppShellUI
OuroWorkbenchApp -> OuroWorkbenchAppViews + adapter/core targets
```

Reusable shell behavior should move upstream to `ouro-native-apple-app-shell`.
Workbench-specific labels, commands, and product decisions should stay in
`OuroWorkbenchCore` or the shell adapter. App views may render shell UI types
through the adapter, but should not grow reusable shell policy locally.

## Shell Control Deck

Workbench's shell boundary is enforced by repo-local scripts that delegate to
the shared shell checkout when needed:

- `scripts/check-shell-boundary.sh` runs the shared shell boundary scanner with
  Workbench's allowlist.
- `scripts/check-shell-dependency.sh` verifies Workbench's `Package.resolved`
  pin still contains the latest package-relevant shared shell changes from
  `main`.
- `scripts/refresh-shell-dependency.sh` updates the shared shell dependency pin.
- `scripts/preflight.sh` is the broad local validation entry point and includes
  shell-boundary checks.

Allowlist rows in `scripts/shell-boundary-allowlist.txt` should stay narrow:
domain behavior and adapter glue are legitimate; reusable app chrome belongs in
the shared shell.

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
