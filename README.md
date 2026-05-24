# Ouro Workbench

Native macOS workbench for terminal agents, with Ouro boss-agent coordination.

Ouro Workbench is a local terminal wrapper for Claude Code, GitHub Copilot CLI,
OpenAI Codex, and arbitrary terminal/TUI agents. It gives those agents durable
workspace state, restart recovery, and a selectable Ouro boss agent that can
answer what is going on, what is waiting on the human, and what should keep
moving.

## P0 Shape

- Native macOS app first.
- Claude Code, GitHub Copilot CLI, and OpenAI Codex are named lanes.
- Arbitrary terminal/TUI agents are first-class citizens.
- `slugger` is the default boss agent on this machine.
- Boss agents can inspect and control trusted workspace processes.
- Sessions restore after app or computer restart wherever technically possible.

## Build

```bash
swift build
swift test
```

Run the native prototype:

```bash
swift run OuroWorkbench
```

Use `New Session` in the Sessions sidebar to add arbitrary terminal/TUI agents
or local commands alongside the default shell and named P0 lanes. Custom
sessions can be edited, duplicated, archived, restored, or deleted from the
native session toolbar; archived sessions remain visible but cannot be launched,
recovered, or controlled by the boss agent until restored.

Package a local `.app` bundle:

```bash
scripts/package-app.sh
open "dist/Ouro Workbench.app"
```

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
selected boss, Workbench MCP registration, trusted P0 lanes, restart posture,
executable availability, recovery state, Boss Watch, and Open at Login. Click it
to see blockers and apply obvious fixes such as registering the MCP bridge,
starting Boss Watch, or enabling launch-at-login.

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
session, and `Command-F` to run the transcript search box.

Use `Recovery Drill` to dry-run restart recovery without mutating workspace
state. It reports which sessions would auto-resume, respawn, require manual
action, or do nothing. Boss agents can run the same dry run with the
`workbench_recovery_drill` MCP tool.

## Architecture

See [docs/architecture.md](docs/architecture.md) and
[docs/recovery.md](docs/recovery.md). Native packaging notes are in
[docs/native-packaging.md](docs/native-packaging.md). The current Ouro bridge
contract is in [docs/ouro-bridge.md](docs/ouro-bridge.md). Surface audit notes
are in [docs/surface-audit.md](docs/surface-audit.md).
