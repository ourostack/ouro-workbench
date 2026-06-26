# Ouro Workbench

Native macOS workbench for terminal agents, with Ouro boss-agent coordination.

Ouro Workbench is a native macOS terminal-agent workbench for Claude Code,
GitHub Copilot CLI, OpenAI Codex, plain shells, and arbitrary terminal/TUI
agents. It gives those sessions durable workspace state, restart recovery, and
a selectable Ouro boss agent that can answer what is going on, what is waiting
on the human, and what should keep moving.

## Product Shape

- Native macOS app first.
- Workbench is a cmux-style terminal workbench: named workspaces in the sidebar,
  with any number of terminal sessions inside each workspace.
- Claude Code, GitHub Copilot CLI, and OpenAI Codex are detected from the
  terminal command instead of living in separate hard-coded tabs.
- Arbitrary terminal/TUI agents are first-class citizens.
- `slugger` is the default boss agent on this machine.
- Local Ouro agents in `~/AgentBundles/*.ouro` are discovered and manageable
  from the native boss pane.
- Boss agents can inspect the group/tab organization and control trusted
  workspace processes.
- Sessions restore after app or computer restart wherever technically possible.

## Guide

Read [docs/guide.md](docs/guide.md) for the operator mental model, first-run
checklist, daily control loops, the attention inbox (the boss handling waiting
prompts for you, preference-driven and audited), boss/Ouro integration, restart
recovery playbook, trust model, and troubleshooting.

Read [docs/product-tour.md](docs/product-tour.md) for the product/investor tour,
release-state summary, and screenshot evidence workflow.

## Build

```bash
swift build
swift test
```

Run the native prototype:

```bash
swift run OuroWorkbench
```

Use `New Workspace` to create a project/workspace scope, then `New Terminal` to add
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

The bundle includes the native app, the packaged Workbench MCP server, the
support diagnostics helper, and the terminal persistence backend under
`Contents/MacOS/Tools/` so normal installed runs do not depend on Homebrew or a
separate multiplexer install. It also includes the Workbench app icon and
SwiftTerm runtime resources.

Install it on this Mac:

```bash
scripts/install-app.sh --open
```

Use the native `Open at Login` switch in the app to reopen Workbench after a
computer restart and trigger session recovery.

Install the latest published ad-hoc-signed preview release with:

```bash
scripts/install-latest-release.sh --open
```

### One-line install (no checkout)

If you just want the app and don't have the repo cloned, run the hosted
installer. It needs only stock macOS tools, downloads the latest published
release, verifies the archive against the release manifest, stages and validates
the app bundle, rolls back the previous install if replacement fails, clears the
Gatekeeper quarantine on the ad-hoc-signed build, and opens it:

```bash
curl -fsSL https://raw.githubusercontent.com/ourostack/ouro-workbench/main/web/workbench-install.sh | bash
```

The installer source lives at
[web/workbench-install.sh](web/workbench-install.sh). Release verification
fetches the immutable raw GitHub copy at the release commit, requires it to
match this source file exactly, and then runs it against the published release.
The optional apex Worker in [apex-worker/](apex-worker/) can re-serve the same
raw source from `ouro.bot/workbench-install.sh` when the branded route is
deployed, but the release gate does not depend on a Cloudflare Pages mirror.
Override behavior with `OURO_WB_REPO`, `OURO_WB_INSTALL_DIR`, or
`OURO_WB_NO_OPEN=1`.

The native boss dashboard also has a `Release Updates` row that checks the
public GitHub Releases feed and opens the latest release page when a newer build
exists.

The installed bundle also includes an Ouro-facing MCP server:

```bash
"/Users/arimendelow/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP"
```

Use the native `Workbench MCP` row in the boss dashboard to register that server
with the selected Ouro boss agent.

Use `Set Up Workbench` from the wand button or command palette for native
onboarding. The flow walks through Welcome, Choose Boss, Connect, and Import
one page at a time. Boss agent rows are selectable across the whole row, and
`Enable Tools` names the Workbench MCP registration step that lets the selected
Ouro boss inspect and control local sessions. Workbench automatically runs the
mandatory live provider checks for the outward and inner lanes before import;
failures block onboarding and route to Ouro's provider repair flow. Once the
boss is ready, onboarding scans recent Claude Code, Codex, Copilot/shell, cmux,
and Workbench sessions, proposes a Desk-shaped group layout, and mirrors
selected work into Desk before resuming a curated starter set of high-confidence
terminals.

The onboarding Setup Assistant stays at the bottom of the sheet. It can ask the
selected boss a setup question and shows the reply inline; direct requests such
as scan, import, or register tools run the matching setup step only after the
same readiness checks as the visible buttons pass.

The import proposal is inspectable before it creates anything. Each proposed
terminal shows its source summary, resume command, and labeled confidence score;
the `Preview` button opens a scrollable chat-style view with the readable
session transcript when Workbench can resolve one, plus the exact evidence paths
used for the proposal.

When migrating from cmux, onboarding also reads cmux's saved workspace state,
matches live Claude Code panes by TTY/session id, preserves cmux workspace names
as Workbench workspaces, and keeps high-trust Claude launch flags such as
`--dangerously-skip-permissions` on the generated resume command. Workbench
does not take over the live cmux PTY; it creates a clean Workbench-owned resume
tab from Claude's session metadata.

Use the `Ouro Agents` row in the boss dashboard to refresh local agent bundle
discovery, switch the boss to an installed local agent, reveal an agent bundle,
register or update Workbench MCP for any discovered agent, or open a managed
terminal for conversational `ouro hatch` or remote-bundle `ouro clone`.

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
external MCP requests. Those actions can operate terminals and organize the
workspace: launch, recover, stop, send input, create workspaces, create terminals,
move stopped sessions, change trust/restart posture, archive, and restore.

Running terminals include `Redraw`, `Ctrl-C`, `Esc`, and `EOF` controls in both
pane and focused modes. `Redraw` sends Ctrl-L, which is the explicit operator
move for refreshing a shell or TUI after resizing without silently clearing live
output. `EOF` sends Ctrl-D for shells and CLIs that use end-of-file to exit or
submit.

The native boss dashboard includes `Support Diagnostics`. It creates a local zip
with system, app-bundle, login-item, runtime, and workspace summary evidence
without copying transcript contents or raw workspace state by default.

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
session, `Command-Shift-F` to focus the running terminal, and `Command-F` to
focus or run transcript search. The palette understands action aliases such as
`diag`, `boss`, `folder`, `mcp`, `signal`, and selected-session verbs, so it can
open diagnostics folders, copy paths, refresh the Workbench, ask the boss about
the current terminal, reveal transcripts, or send terminal signals without
digging through the dashboard.

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
matrix is in [docs/cmux-workbench-test-matrix.md](docs/cmux-workbench-test-matrix.md),
and the canonical 5000-row scenario matrix is in
[docs/workbench-5000-scenario-matrix.md](docs/workbench-5000-scenario-matrix.md).
