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

Use `New Session` in the Terminal Agents sidebar to add arbitrary terminal/TUI
agents or local commands alongside the named P0 lanes.

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

## Architecture

See [docs/architecture.md](docs/architecture.md) and
[docs/recovery.md](docs/recovery.md). Native packaging notes are in
[docs/native-packaging.md](docs/native-packaging.md). The current Ouro bridge
contract is in [docs/ouro-bridge.md](docs/ouro-bridge.md).
