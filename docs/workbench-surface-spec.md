# Ouro Workbench Surface Spec

Status: draft for review

This document defines the product story, user-visible surfaces, and behavior
rules for Ouro Workbench. Implementation should converge on this spec before
adding new features.

## Product Story

Ouro Workbench is a native macOS terminal multiplexer for terminal/TUI coding
agents.

The user brings real local agents and terminals: Claude Code, Codex, GitHub
Copilot, shells, and future tools. Workbench does not replace those agents. It
wraps them in a recoverable terminal environment and gives a selected Ouro boss
agent the ability to inspect, read, write, resume, and coordinate all terminal
sessions.

The core loop is:

1. Set up a functioning Ouro boss agent.
2. Let that agent inspect local running and recently run coding-agent sessions.
3. Let the agent propose what to import and how to organize it.
4. Resume selected sessions inside Workbench.
5. Let the agent guide the user to close duplicate sessions still running
   outside Workbench.
6. Keep terminal content and recovery metadata durable across app crashes,
   restarts, and computer reboots.

Anything that does not support that loop is secondary. Secondary surfaces may
exist, but they must not muddy the first-run or everyday story.

## Core Nouns

### This Mac

`This Mac` is the machine scope. It means "the local computer Workbench is
watching."

It is not a sidebar container, not a workspace, and not a group. It may appear
in setup copy, diagnostics, and boss context when the app is explaining which
machine is being scanned.

### Boss Agent

The boss agent is the selected Ouro agent that owns Workbench coordination.

The boss can inspect session state, read transcripts, write to terminals through
approved Workbench actions, propose imports, recover sessions, and explain what
is happening. The user may eventually select multiple Ouro agents, but the first
complete product has one active boss for the machine.

### Workspace

A workspace is an organizational bucket for sessions. In most cases it maps to a
project, repository, folder, or imported external workspace.

The UI should use `Workspace`, not `Group`, for this concept. Workspaces are
created by import proposals, user actions, or explicit workspace files. There
should be no default `This Mac` workspace on first run.

If a session cannot be confidently assigned, place it in `Unsorted Sessions`
or let the boss ask the user where it belongs.

### Session

A session is a Workbench-managed terminal entry with durable metadata:

- terminal command
- working directory
- detected harness/agent kind
- owner: human or agent
- transcript path
- resume strategy
- recovery status
- evidence paths when imported from outside Workbench

A session may be running, stopped, recoverable, archived, or imported but not
yet launched.

### Import Candidate

An import candidate is a session Workbench found outside itself. It is not a
Workbench session until the user approves import.

Candidates must carry evidence: process info, transcript path, history file,
database row, or other local artifact. If the evidence is weak, the boss should
ask before importing.

## Surface Principles

1. The terminal owns the screen.
2. The boss agent owns complexity.
3. Traditional setup UI exists only until a functioning boss agent exists.
4. After boss readiness, setup becomes conversational and visual.
5. Low-level terminal controls are advanced controls, not primary product
   concepts.
6. Recovery truth matters. Do not claim a process survived reboot. Say resumed,
   respawned, recovered, or needs manual recovery.
7. Every visible control must answer a user-level question. If the answer is a
   terminal escape sequence, hide it behind advanced controls.
8. New features must fit the story before they appear in primary UI.

## Current Surface Inventory And Disposition

This inventory maps the current app surface area to the target product. A
surface marked `Primary` may appear in normal use. `Contextual` appears only
when state calls for it. `Advanced` remains reachable but does not lead the
story. `Merge` means the surface should be folded into a simpler primary or
contextual surface. `Remove/Defer` means it should not ship as a distinct
surface in the simplified product unless a future spec reintroduces it.

| Current surface | Target disposition | Target shape |
| --- | --- | --- |
| Root window | Primary | Multiplexer: sidebar, terminal, boss conversation/status. |
| Sidebar filter | Advanced or contextual | Useful after many sessions exist; not first-run chrome. |
| Sidebar `Agents` section | Merge | Collapse into compact boss readiness/status. Full agent management is advanced. |
| Sidebar `Groups` section | Rename/Merge | Rename concept to `Workspaces`; never show `This Mac` as a group. |
| Sidebar selected project/session split | Primary | Workspaces contain sessions. Selection opens terminal. |
| Sidebar `Archived` section | Contextual | Show only when archived sessions exist. |
| Sidebar `Recovery` section | Contextual | Show only when recovery needs action. |
| `This Mac` default project | Remove/Defer | Machine scope only. Do not create as default workspace after reset. |
| Built-in `Local Shell` | Remove/Defer | Do not seed before setup/import. If created later, it must be removable. |
| Header boss controls | Merge | Replace with compact boss status plus conversation entry point. |
| Boss selector | Contextual | First-run/setup or advanced boss management. |
| Autonomy status button/popover | Advanced | Boss can explain readiness. Show only compact status if needed. |
| Command palette | Advanced | Accelerator only. Never required for setup/import/recovery. |
| Boss dashboard metrics/visibility/mailbox panels | Merge | Boss conversation can present state on demand. Avoid dashboard-first UI. |
| Boss conversation | Primary | Main agentic control surface. |
| Habit history panel | Advanced | Not part of core terminal multiplexer story. |
| Ouro agent manager | Advanced | Useful later for multi-agent management; not daily primary. |
| Provider config sheet | Contextual | Human credential gate during agent setup/repair. |
| Ouro agent install sheet | Contextual | Agent setup: hatch/clone/select. |
| Onboarding wizard | Contextual | Only until a boss agent works; then hand off to boss conversation. |
| Onboarding import proposal | Merge | Becomes boss-led visual proposal, not a standalone static wizard step. |
| Harness status sheet | Advanced | Support/debug unless boss surfaces a concrete repair. |
| Decision log/inbox sheets | Advanced | Audit/support details. Boss should narrate decisions in plain language. |
| Recovery sheet | Contextual | Only when something needs recovery. |
| Recovery drill | Advanced | Diagnostic/support tool, not primary recovery UX. |
| Settings sheet | Advanced | Durable preferences only. |
| Shortcut help sheet | Advanced | Optional help. |
| About sheet | Advanced | Standard app surface. |
| Report bug/support diagnostics | Advanced | Support path. |
| Import summary banner | Contextual | Short confirmation after import. |
| New/edit workspace sheets | Advanced/contextual | Only when user explicitly organizes. |
| New/edit session sheets | Advanced/contextual | Direct manual creation/editing remains possible but secondary to import. |
| Agent detail view | Advanced | Future multi-agent management, not core first-run/day-one. |
| Session detail view | Primary | Terminal content and simple session state. |
| Split pane | Advanced | Useful for power users; not first-run or required core flow. |
| Empty pane picker | Advanced | Only when split pane is active. |
| Terminal search bar | Contextual | Appears only during find. |
| Session title strip | Primary | Name, concise state, simple action, more menu. |
| Session inspector panel | Advanced | Evidence, command, transcript, recovery details. Closed by default. |
| Session transcript sheet | Contextual | Open when user/boss asks to inspect transcript. |
| Inactive terminal surface | Primary | Clear launch/resume/recover action. |
| Transcript rehydration preview | Contextual | Useful for stopped/recoverable sessions. |
| Running session control strip | Merge/Advanced | Collapse to labeled `Session Controls`; no unexplained icon row. |
| Terminal focus view | Advanced | Full terminal mode with minimal controls. |
| Machine runtime view | Advanced | Diagnostic/support. |
| Release update view | Advanced/contextual | Settings/update surface, not core workspace. |
| Menu bar item | Contextual | Compact attention entry point only. |
| Terminal pane | Primary | The core product surface. |

Any implementation work that introduces or keeps a primary surface outside this
table must update the spec first.

## First-Run Behavior

### Entry Conditions

First-run starts when:

- no Workbench state exists,
- factory reset requested setup,
- no functioning boss agent exists,
- the selected boss cannot use Workbench tools, or
- the user explicitly opens setup.

Factory reset must force setup on the next launch. It must not rely only on
readiness inference, because a machine can have a healthy boss while the user
still asked to re-run the Workbench setup experience.

### Step 1: Agent Setup

This is the only traditional setup wizard.

Required choices:

- select an existing usable Ouro agent,
- hatch a new agent, or
- repair/connect the selected agent.

The surface may ask for human-only credentials through native forms. It must not
ask the user to run terminal commands by hand when the app can execute verified
setup actions itself.

No terminal-session import UI, session-management chrome, or default local shell
should block this step.

### Step 2: Agent Welcome

Once the boss agent can answer through Workbench tools, the wizard ends and the
boss welcomes the user.

The welcome should be conversational:

- "I can see this Mac now."
- "I will look for local coding-agent sessions."
- "I will ask before importing anything unclear."

The app may show visual cards, but the boss is the narrator and decision maker.

### Step 3: Scan and Import Proposal

The boss initiates or confirms a scan for:

- running Workbench sessions,
- running external terminal/TUI agent processes,
- recent Claude Code CLI sessions,
- recent Claude Code app/task/session records when present,
- recent Codex CLI sessions,
- recent Codex app/archived/manual-recovery records when present,
- recent GitHub Copilot CLI/app evidence when present,
- cmux state,
- shell history that launched coding agents,
- other local evidence that looks like a coding-agent session.

Known paths are hints, not the whole system. The boss should be allowed to
inspect additional local evidence through Workbench tools or a bounded scanner.

The boss classifies each candidate:

- likely unfinished and worth importing,
- finished/low-value and probably skip,
- ambiguous and needs a user question,
- unsafe/unsupported and skip with explanation.

The visual proposal shows:

- proposed workspace,
- session name,
- detected harness,
- working directory,
- resume command,
- evidence,
- confidence/reason,
- import/skip toggle.

The user approves or edits the proposal.

### Step 4: Resume and Duplicate Cleanup

After import, Workbench resumes approved sessions inside Workbench when a safe
resume strategy exists.

If matching external sessions are still running, the boss explains the duplicate
risk and guides the user to close or stop those outside sessions. Workbench may
offer safe app-executed stop actions only when it can prove the target process
belongs to the imported session.

## Main Window

The main window has three conceptual regions:

1. Sidebar: workspaces and sessions.
2. Terminal area: selected session content.
3. Boss conversation or compact boss status.

The app should not present a dashboard before there are sessions. Empty state
should route the user to setup or boss-led import.

## Sidebar

The sidebar is an index, not a control panel.

Primary sections:

- Boss: compact status only, with setup/repair action if not ready.
- Workspaces: project/repo/folder buckets containing sessions.
- Recovery: visible only when something needs action.

Do not show both `Groups` and `This Mac`. Use `Workspaces` for containers and
reserve `This Mac` for machine-scope copy.

Do not show an `Agents` section as a permanent peer to sessions unless multiple
agent management is an active product surface. The selected boss status is
enough for the first product.

## Workspace Rows

A workspace row shows:

- name,
- optional path/repo,
- count of sessions,
- attention summary when any session needs the user.

Actions:

- rename,
- reorder,
- delete only when empty,
- color/tag only if it earns its keep in the final visual system.

Workspace management is secondary. It should not compete with session recovery
or boss prompts.

## Session Rows

A session row shows:

- session name,
- detected harness/agent kind,
- running/stopped/recoverable/waiting state,
- owner when agent-owned,
- concise activity summary when available.

Primary row actions:

- select,
- launch/resume when stopped,
- stop when running and safe,
- more actions.

Advanced row actions:

- copy launch command,
- open working directory,
- edit saved command,
- archive,
- delete,
- move workspace.

Built-in fallback sessions must not be undeletable dead ends. If Workbench
creates a fallback session, it must either be hidden until useful or removable
by the user.

## Terminal Area

The terminal area should prioritize live terminal content.

Running session primary chrome:

- session name,
- status dot or short status,
- stop only when running,
- more/session controls menu.

Stopped session primary chrome:

- status,
- launch/resume/recover button,
- last transcript preview if useful,
- command preview only if it helps explain what will launch.

Low-level controls such as focus, redraw, Ctrl-C, Esc, Ctrl-D/EOF, and raw stop
must not be a row of unexplained primary buttons. They belong in `Session
Controls` or an advanced menu with labels.

The boss may invoke these controls through audited Workbench actions when
appropriate.

## Boss Surface

The boss surface is a conversation, not a dashboard.

It supports:

- "what is going on?",
- "is anything waiting on me?",
- "keep things moving",
- setup/import narration,
- clarification questions,
- proposed actions,
- recovery explanations.

The boss can show visual support panels:

- import proposal,
- ambiguous sessions to decide,
- recovery list,
- action confirmation when human approval is needed.

The boss surface should avoid raw implementation panels unless the user opens
advanced details.

## Recovery Surface

Recovery is P0 but should be quiet when healthy.

Visible recovery states:

- no action needed: no primary recovery surface,
- recoverable sessions exist: compact sidebar row or banner,
- recovery failed: clear explanation and next safe action,
- external duplicate detected: boss-guided cleanup.

Recovery actions must classify truthfully:

- reattached to live process,
- resumed from native harness metadata,
- relaunched latest session fallback,
- cannot recover automatically.

## Settings

Settings contain durable preferences only:

- terminal font size,
- terminal theme,
- auto-update,
- login item,
- privacy/import scan controls if needed.

Settings must not become the primary way to configure agents or import work.
Agent setup belongs in first-run or boss-guided repair.

## Command Palette

The command palette is an advanced accelerator. It may remain for power users,
but it must not be required for first-run, import, recovery, or normal session
control.

Palette commands should mirror visible or boss-available actions.

## Diagnostics and Action Logs

Diagnostics, raw action logs, harness status, MCP registration details, and
debug panels are advanced surfaces.

They are useful for development and support, but should not appear in first-run
or primary daily UI unless the boss is explaining a specific issue.

## Menu Bar Status

The menu bar item, if enabled, is a compact attention surface:

- number of running sessions,
- waiting-on-user count,
- quick open Workbench,
- ask boss.

It should not duplicate the full sidebar or expose low-level terminal controls.

## Factory Reset

Factory reset clears Workbench-owned state and preferences, backs up prior
Workbench state, stops Workbench-managed terminals, and relaunches into setup.

It must not delete agent-owned session history.

After reset:

- no default `This Mac` workspace should be selected as if it were imported
  work,
- no undeletable local shell should be the only visible session,
- setup must appear even when the Ouro boss is already healthy,
- the boss should lead import once ready.

## Import Scanner Requirements

The scanner should have deterministic built-in adapters for known sources:

- Claude Code project JSONL,
- Claude task/session records,
- live Claude processes,
- cmux session state,
- Codex SQLite/session index,
- Codex archived JSONL,
- Codex manual-recovery/rollout JSONL,
- GitHub Copilot shell/history evidence,
- Workbench existing state,
- shell history launches.

The boss-led layer may ask broader questions and request bounded local scans,
but deterministic adapters should provide evidence-backed candidates.

Every candidate must include:

- source,
- detected kind,
- title,
- working directory,
- last active time if known,
- resume command,
- evidence paths,
- confidence,
- reason/summary.

## Safety Model

The boss may read Workbench state and transcripts.

The boss may write to Workbench-managed terminals through audited actions.

The boss should not silently perform destructive operations, leak secrets, or
close unrelated external processes. Human-only gates remain:

- credentials and provider dashboards,
- destructive operations outside Workbench-owned state,
- unclear product decisions,
- stopping external processes that cannot be confidently matched.

## Implementation Priorities

1. Fix reset so it forces setup and does not recreate an undeletable shell-only
   dead end.
2. Rename or remove the `Groups` / `This Mac` confusion from primary UI.
3. Collapse low-level terminal-control chrome into advanced session controls.
4. Make first-run agent setup narrow and unavoidable when no boss is ready.
5. Turn post-agent import into a boss-led conversational flow with visual
   proposal support.
6. Expand deterministic import adapters for Codex and Claude local stores.
7. Resume approved sessions in Workbench and guide duplicate external cleanup.

## Explicit Non-Goals

- Web-first client.
- Replacing Claude Code, Codex, Copilot, or shell agents.
- A fixed "Claude mode" or "Codex mode."
- A permanent traditional setup wizard after the boss agent is functional.
- Primary UI for internal implementation details.
- Extra dashboards that do not answer a user-level question.
