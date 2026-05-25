# Ouro Workbench

Native macOS workbench for terminal agents, with Ouro boss-agent coordination.

Ouro Workbench is a local terminal wrapper for Claude Code, GitHub Copilot CLI,
OpenAI Codex, and arbitrary terminal/TUI agents. It gives those agents durable
workspace state, restart recovery, and a selectable Ouro boss agent that can
answer what is going on, what is waiting on the human, and what should keep
moving.

## Product Shape

- Native macOS app first.
- Workbench is a cmux-style terminal workbench: named groups in the sidebar,
  with any number of terminal tabs inside each group.
- Claude Code, GitHub Copilot CLI, and OpenAI Codex are detected from the
  terminal command instead of living in separate hard-coded tabs.
- Arbitrary terminal/TUI agents are first-class citizens.
- `slugger` is the default boss agent on this machine.
- Boss agents can inspect the group/tab organization and control trusted
  workspace processes.
- Sessions restore after app or computer restart wherever technically possible.

## Guide

Read [docs/guide.md](docs/guide.md) for the operator mental model, first-run
checklist, daily control loops, boss/Ouro integration, restart recovery
playbook, trust model, and troubleshooting.

## Build

```bash
swift build
swift test
```

Run the native prototype:

```bash
swift run OuroWorkbench
```

Use `New Group` to create a project/workspace scope, then `New Terminal` to add
Claude Code, GitHub Copilot CLI, OpenAI Codex, local shells, or any other
terminal/TUI agent inside that group. Workbench detects known CLI identities
from the command and adjusts recovery, health, and boss prompts accordingly.
Terminal tabs can be edited, duplicated, archived, restored, or deleted from the
native session toolbar; archived sessions remain visible but cannot be launched,
recovered, or controlled by the boss agent until restored.

Package a local `.app` bundle:

```bash
scripts/package-app.sh
open "dist/Ouro Workbench.app"
```

The bundle includes the native app, the packaged Workbench MCP server, and the
terminal persistence backend under `Contents/MacOS/Tools/` so normal installed
runs do not depend on Homebrew or a separate multiplexer install.

Install it on this Mac:

```bash
scripts/install-app.sh --open
```

Use the native `Open at Login` switch in the app to reopen Workbench after a
computer restart and trigger session recovery.

The installed bundle also includes an Ouro-facing MCP server:

```bash
"/Users/arimendelow/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP"
```

Use the native `Workbench MCP` row in the boss dashboard to register that server
with the selected Ouro boss agent.

The `TTFA` badge in the header is an autonomy readiness surface. It checks the
selected boss, Workbench MCP registration, detected trusted agent terminals,
restart posture, executable availability, recovery state, Boss Watch, and Open
at Login. Click it to see blockers and apply obvious fixes such as registering
the MCP bridge, starting Boss Watch, or enabling launch-at-login.

The boss dashboard also includes `Watch` mode. When enabled, Workbench keeps a
rolling baseline of workspace state, summarizes changes such as run transitions,
attention changes, archive/restore operations, and applied actions, then asks
the selected boss agent to keep trusted work moving when there is something new
or recoverable to handle.

Use `Boss Line` to ask the selected Ouro boss about the Workbench through the
Ouro CLI. The quick asks cover "what is going on?", "is anything waiting on me?",
"keep moving", and "respond for me"; boss replies can include auditable
Workbench actions that the native app applies through the same trust gates as
external MCP requests.

Each session header also has an `Ask Boss` button for focused questions about
that terminal. It gives the boss the selected process id and asks whether the
session is waiting, what it is doing, and whether a safe Workbench action should
move it forward.

Use `Transcript Search` in the boss dashboard to search saved transcript lines
across Workbench runs. Boss agents can use the same capability through the
`workbench_search_transcripts` MCP tool. Results are ordered by newest run first,
then by line order within each transcript.

Press `Command-K` to open the native command palette. Common shortcuts include
`Command-N` for a new session, `Command-I` for boss check-in, `Command-Return`
to launch or restart the selected session, `Command-.` to stop a running
session, and `Command-F` to focus or run transcript search.

Use `Recovery Drill` to dry-run restart recovery without mutating workspace
state. It reports which sessions would auto-resume, respawn, require manual
action, or do nothing. Boss agents can run the same dry run with the
`workbench_recovery_drill` MCP tool.

## Architecture

See [docs/architecture.md](docs/architecture.md) and
[docs/recovery.md](docs/recovery.md). Native packaging notes are in
[docs/native-packaging.md](docs/native-packaging.md). The current Ouro bridge
contract is in [docs/ouro-bridge.md](docs/ouro-bridge.md). Surface audit notes
are in [docs/surface-audit.md](docs/surface-audit.md). The 500+ case audit
matrix is in [docs/cmux-workbench-test-matrix.md](docs/cmux-workbench-test-matrix.md).
