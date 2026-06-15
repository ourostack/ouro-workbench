# Workbench Surface Spec Audit Report

Status: routed for autonomous implementation
Date: 2026-06-14
Canonical spec: `docs/workbench-surface-spec.md`
Planning doc: `worker/tasks/2026-06-14-1420-planning-factory-reset-setup-flow.md`

## Addendum: Product Center Of Gravity Pass

Date: 2026-06-14
Ideation doc: `worker/tasks/2026-06-14-1939-ideation-product-center-of-gravity.md`

The reset/setup tranche fixed the immediate screenshot path: factory reset now
writes a setup marker after wiping state, setup-mode bootstrap uses `Unsorted
Sessions`, and the live E2E artifact proves no reset-created `Local Shell` is
present in first-run setup.

The user's follow-up correctly identified a deeper issue: the product still has
a built-in `Local Shell` primitive in normal bootstrap and startup code. That is
architectural drift, not just copy drift. The correct center of gravity is:
Workbench is a boss-coordinated terminal/TUI multiplexer; shells are ordinary
managed sessions, never default identity.

Current evidence:

- `Sources/OuroWorkbenchCore/WorkbenchBootstrapper.swift:10` still defaults the
  empty workspace name to `This Mac`.
- `Sources/OuroWorkbenchCore/WorkbenchBootstrapper.swift:13` still defaults
  `includeLocalShell` to true.
- `Sources/OuroWorkbenchCore/WorkbenchBootstrapper.swift:63` inserts or repairs
  `BuiltInWorkbenchSessions.localShell` when that flag is true.
- `Sources/OuroWorkbenchCore/WorkbenchBootstrapper.swift:147` still gives the
  shell a dedicated built-in lifecycle and `Local Shell` name.
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:387` still calls
  `launchDefaultShellIfNeeded()` during app startup.
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:14012` still auto-launches
  the first auto-launchable built-in shell when no sessions are active.
- `Sources/OuroWorkbenchMCP/main.swift:477` bootstraps read-only state with the
  same defaults, so the boss-facing MCP can synthesize a `Local Shell` even
  when the app should report setup/no imported sessions truth.
- `Sources/OuroWorkbenchCore/CustomTerminalSession.swift:108` treats only
  `.terminalAgent` rows as managed custom sessions, so persisted `.shell` rows
  do not receive edit/archive/delete affordances.
- `Tests/OuroWorkbenchCoreTests/WorkbenchBootstrapperTests.swift:5` still
  asserts the old desired behavior: empty bootstrap creates `Local Shell` only.
- `README.md:5`, `docs/roadmap.md:9`, and `docs/roadmap.md:184` still encode the
  old wrapper/default-shell story.

New routed findings:

- **A-011 - Built-in shell remains the normal empty-state center.**
  The reset-specific path opts out, but ordinary empty-state bootstrap and app
  startup still assert that Workbench should create/launch a special shell.
- **A-012 - Persisted shell rows are not normal managed sessions.**
  Any existing `.shell` row still lacks the normal edit/archive/delete lifecycle
  because custom-session management only accepts `.terminalAgent`.
- **A-013 - Docs still teach the old shell/wrapper story.**
  README/guide/roadmap copy can steer implementation back toward a local shell
  launcher even after the UI behavior is corrected.
- **A-014 - Scenario fixtures still canonize `Local Shell`.**
  Scenario coverage may include shell sessions, but naming them `Local Shell`
  as a canonical identity keeps the old product story alive in generated
  validation artifacts.

## Summary

The reported experience is explained by three interacting defects:

1. Factory reset removes Workbench state, but next launch immediately bootstraps a
   default `This Mac` project and `Local Shell`.
2. Onboarding auto-presentation is readiness-driven, so a healthy existing Ouro
   boss can suppress first-run setup even after an explicit factory reset.
3. The main session chrome exposes low-level terminal driver controls as primary
   UI, making the reset-created shell look like the intended product.

The codebase already has useful primitives to build the right product: a
non-destructive factory reset helper, a configurable bootstrapper, a recent
session scanner, persistent screen-backed terminal sessions, recovery metadata,
and boss/MCP action infrastructure. The work should therefore focus on changing
launch/setup state, simplifying primary chrome, and expanding deterministic
import adapters rather than replacing the runtime.

## Manifest

Audited source shape:

- `Sources/OuroWorkbenchApp`: 3 files, 17036 lines.
- `Sources/OuroWorkbenchCore`: 79 files, 16390 lines.
- `Sources/OuroWorkbenchMCP`: 1 file, 756 lines.
- `Sources/OuroWorkbenchScenarioVerifier`: 1 file, 1206 lines.
- `Tests/OuroWorkbenchCoreTests`: 83 files, 14817 lines.
- Repository total observed: 205 files, 60966 lines.

Largest files:

- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`: 16770 lines.
- `docs/workbench-5000-scenario-matrix.tsv`: 5001 lines.
- `Sources/OuroWorkbenchCore/Onboarding.swift`: 1613 lines.
- `Sources/OuroWorkbenchScenarioVerifier/main.swift`: 1206 lines.
- `Tests/OuroWorkbenchCoreTests/OnboardingTests.swift`: 899 lines.
- `docs/guide.md`: 861 lines.
- `Sources/OuroWorkbenchCore/WorkbenchVisibility.swift`: 831 lines.
- `Sources/OuroWorkbenchMCP/main.swift`: 756 lines.

The app layer is the central risk. `OuroWorkbenchApp.swift` contains the root
view, most sheets, sidebar, boss dashboard, onboarding UI, terminal UI, focus
mode, menu wiring, and `WorkbenchViewModel`. Core modules are much healthier:
factory reset, bootstrap, onboarding scanner, action planning, recovery, and
visibility each have focused tests and mostly pure seams.

## Documentation Notes

The new canonical spec says Workbench is a native terminal multiplexer with one
selected Ouro boss agent owning coordination and complexity. It explicitly
demotes `Groups`, `This Mac` as a container, default `Local Shell`, dashboard
panels, and low-level terminal controls from primary first-run UI.

Older docs still describe the prior product posture:

- `docs/product-tour.md:3` calls Workbench a "command center", and
  `docs/product-tour.md:29` describes groups on the left and boss controls
  across the top.
- `docs/product-tour.md:34` lists `TTFA`, `Commands`, `Watch`, `Check In`, and
  raw selected-terminal controls as key controls.
- `docs/surface-audit.md:7` scopes the old audit around "cmux-style groups",
  and `docs/surface-audit.md:74` treats boss dashboard and command palette as
  verified primary surfaces.
- `docs/architecture.md:10` and `docs/guide.md:296` still describe `Groups` as
  the user-facing container noun.

These docs should not drive implementation anymore. They are backlog items to
update after the simplified flow lands.

## Critical Flow Trace

### Factory Reset To Relaunch

- The reset confirmation says reset clears Workbench-owned data and relaunches
  into first-run setup (`Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:486`).
- `resetToFirstRun()` suppresses save, terminates live sessions, calls
  `WorkbenchFactoryReset.wipeData`, synchronizes defaults, relaunches, then
  terminates (`Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:9228`).
- `WorkbenchFactoryReset.wipeData` moves the state file aside and removes the
  entire Workbench defaults domain (`Sources/OuroWorkbenchCore/WorkbenchFactoryReset.swift:21`).
- On next launch, app startup calls `launchDefaultShellIfNeeded()` before
  readiness/onboarding decisions (`Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:369`).
- `shouldPresentOnboardingOnLaunch` returns false whenever readiness is already
  ready (`Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:9668`).
- The bootstrapper defaults to project name `This Mac` and
  `includeLocalShell: true` (`Sources/OuroWorkbenchCore/WorkbenchBootstrapper.swift:3`),
  then inserts `BuiltInWorkbenchSessions.localShell` when no local shell exists
  (`Sources/OuroWorkbenchCore/WorkbenchBootstrapper.swift:52`).

Result: reset succeeds at deleting state, but a healthy boss can skip setup and
the empty bootstrap state becomes an auto-launched `Local Shell`.

### Sidebar And Session Chrome

- The sidebar always exposes a filter field, `Agents`, `Groups`, selected-group
  `Terminals`, and `Recovery` sections (`Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:2587`).
- `TerminalRowContextMenu` exposes delete/archive/edit only when
  `model.isCustomSession(entry)` is true (`Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:2941`).
- `RunningSessionHeaderControls` places focus, redraw, Ctrl-C, Esc, EOF, and
  stop in a visible icon row (`Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:7835`).
- Focus mode repeats the low-level controls in a floating control strip
  (`Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:7935`).

Result: the only visible post-reset session is a built-in entry the user cannot
remove, surrounded by advanced terminal escape controls presented as normal UI.

### Onboarding And Import

- Onboarding text commands are interpreted by string matching for "scan",
  "apply", "arrange", "import", "mcp", and "hatch"
  (`Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:12519`).
- `scanForOnboardingSessions()` calls `RecentSessionScanner().scan()` and
  separately scans current Workbench state, then builds a static proposal
  (`Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:12563`).
- `applyOnboardingProposal()` turns selected proposal items into trusted
  auto-resume custom sessions and launches them (`Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:12615`).
- `RecentSessionScanner.scan()` covers Workbench, cmux, live Claude, Claude
  project JSONL, Codex SQLite or session index, and shell history
  (`Sources/OuroWorkbenchCore/Onboarding.swift:530`).
- `scanCodex()` returns SQLite candidates immediately when present, so
  `session_index.jsonl` is not also considered (`Sources/OuroWorkbenchCore/Onboarding.swift:728`).

Result: the import foundation exists, but the flow is app-led/static rather
than boss-led/conversational, and known local Codex/Claude stores are missing.

## Control Deck Assessment

External state and configs that affect this flow:

- Workbench state: `~/Library/Application Support/OuroWorkbench/workspace-state.json`.
- Workbench defaults domain: `WorkbenchRelease.bundleIdentifier`.
- Reset backups: sibling `workspace-state.<epoch>.bak.json` files.
- Codex stores observed locally: `~/.codex/state_5.sqlite`,
  `~/.codex/session_index.jsonl`, `~/.codex/archived_sessions/*.jsonl`, and
  `~/.codex/manual-recovery-*/*.jsonl`.
- Claude stores observed locally: `~/.claude/projects/**/*.jsonl` and
  `~/.claude/tasks/**`.
- cmux store: `~/Library/Application Support/cmux/session-com.cmuxterm.app.json`.
- Shell history: `~/.zsh_history`.

The biggest predictability gap is the absence of an explicit "reset requested
setup" marker. Without that marker, launch behavior is inferred from boss
readiness, bootstrap state, and auto-launch shell state, which is not what the
reset dialog promises.

## Findings

### Critical

**A-001 - Factory reset does not force setup.**
The reset path wipes data, but onboarding is gated only by readiness/config gaps.
When an existing boss is healthy, first-run setup can be skipped.

**A-002 - Bootstrap recreates the confusing shell-only state.**
Empty state is rehydrated as a `This Mac` project with an auto-launchable
`Local Shell`, which violates the spec's reset behavior and matches the user
screenshot.

### High

**A-003 - Built-in fallback sessions are undeletable dead ends.**
The context menu hides edit/archive/delete unless the entry is custom, so the
reset-created `Local Shell` cannot be removed from normal UI.

**A-004 - Low-level terminal controls are primary chrome.**
Focus, redraw, Ctrl-C, Esc, EOF, and stop are shown as a compact unlabeled icon
row in normal running-session headers. The spec says these are advanced session
controls or boss-owned actions.

**A-005 - Primary IA still says Agents, Groups, This Mac, Terminals, Recovery.**
The sidebar presents several product concepts as peers, including the old
`Groups` noun and a permanent `Agents` section, which muddies the intended
terminal multiplexer story.

**A-006 - Onboarding/import is app-led string routing, not boss-led setup.**
The scanner/proposal code is useful, but the flow does not yet have the boss
warmly welcome the user, classify unfinished work, ask about ambiguous
candidates, and guide duplicate cleanup.

**A-007 - Import scanner misses known Codex and Claude stores.**
The scanner does not enumerate Codex archived/manual-recovery JSONL files or
Claude task records, and the SQLite early return can hide session-index
evidence.

### Medium

**A-008 - `OuroWorkbenchApp.swift` is a god file.**
The app file's size and mixed responsibilities make spec-driven UI changes
riskier. This should be split after the first-run/user-facing fixes land.

**A-009 - Current docs and scenario wording encode the old product.**
Docs and verifier labels still say "groups", "command center", "boss controls",
and raw full-screen controls. They should be updated after behavior converges.

**A-010 - MCP/action names still expose old organization language.**
The boss-control layer advertises `createGroup` and related group-oriented
actions in docs and likely in MCP schemas. This is tolerable internally for now,
but public/boss-facing names should converge on Workspaces.

## Healthy Parts To Preserve

- Reset is non-destructive to harness-owned history and already backs up
  Workbench state before removal.
- Startup recovery is truth-oriented: app code distinguishes reattach, recover,
  respawn, and manual action instead of pretending processes survive reboot.
- Bootstrapper already accepts `WorkbenchDefaults(includeLocalShell:)`, so
  setup-mode shell suppression can be implemented without rewriting bootstrap.
- `RecentSessionScanner` already has testable pure seams: injected home URL,
  file manager, lookback, sqlite path, cmux path, and live process lister.
- Import proposals already carry evidence paths, confidence, resume commands,
  and repository-root grouping.
- Existing tests cover bootstrap, factory reset data wipe, onboarding scanners,
  proposal grouping, recovery, and scenario rendering.

## Recommended Execution

Execute the planner-required tranche now because A-001 through A-007 are the
same user-facing failure chain. Defer broad app-file modularization and old-doc
renames until after the first coherent reset/setup/import pass lands and is
validated live.

The immediate implementation should:

1. Add a reset/setup marker that survives preference wipe and forces onboarding
   on the next launch.
2. Use setup-mode bootstrap to avoid creating/auto-launching the fallback
   `Local Shell` during reset first-run.
3. Ensure any fallback shell that remains after setup is removable or hidden
   until useful.
4. Collapse running-session header controls into a labeled advanced
   `Session Controls` menu, leaving stop as the only visible running action when
   appropriate.
5. Rename visible `Groups` labels to `Workspaces` in primary UI and hide
   always-on advanced sections that do not have state.
6. Make the post-agent onboarding copy/flow explicitly boss-led and
   conversational, using the existing proposal visual as support.
7. Expand deterministic import adapters for Codex archived/manual-recovery
   JSONL and Claude task stores, preserving existing coverage.
