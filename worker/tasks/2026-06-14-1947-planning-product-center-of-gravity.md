# Planning: Product Center Of Gravity

**Status**: approved
**Created**: 2026-06-14 19:47

## Goal

Make Ouro Workbench's default/fresh/reset state enforce the actual product
center: a boss-coordinated terminal/TUI workbench where workspaces contain
durable sessions, and a plain shell is only an ordinary managed session the
user or boss explicitly creates/imports.

This pass removes the remaining built-in `Local Shell` lifecycle from normal
bootstrap, startup, MCP truth, tests, scenarios, and current product docs while
preserving existing user-owned shell sessions and their recovery/auto-resume
behavior.

## Upstream Work Items

- A-011
- A-012
- A-013
- A-014

## Scope

### In Scope

- Change normal empty-state bootstrap so it creates a minimal setup/unsorted
  workspace and zero process entries.
- Stop using `This Mac` as the default workspace name for empty state; reserve
  that phrase for machine-scope copy.
- Remove built-in shell creation, repair, and fallback launch authority:
  - no bootstrap insertion of `BuiltInWorkbenchSessions.localShell`,
  - no load-time repair that rewrites a persisted shell's executable, trust, or
    auto-resume,
  - no startup `launchDefaultShellIfNeeded()` path.
- Ensure the MCP server's read-only state bootstrap does not synthesize a
  `Local Shell` or otherwise fabricate a session that is not in persisted state.
- Preserve existing `.shell` rows as user data. They should continue to appear,
  launch, recover, and auto-resume when the explicit auto-resume preference
  applies.
- Treat `.shell` rows as normal managed terminal sessions for edit, duplicate,
  move, archive, restore, delete, and boss archive/restore paths.
- Update tests that currently assert the old default shell behavior:
  - invert default bootstrap tests around no process entries,
  - add imported shell preservation tests,
  - add managed shell lifecycle tests,
  - cover MCP/read-only bootstrap if a test seam exists or can be introduced
    cleanly.
- Rename scenario fixtures away from canonical `local_shell` / `Local Shell`
  product language while keeping generic/imported shell coverage.
- Update current product docs and active roadmap lines that teach Workbench as a
  local shell/default terminal launcher.
- Update active audit/spec/backlog status after implementation.
- Run full unit tests, scenario verifier, build/package/install, and live E2E
  validation against a fresh support root and a imported shell fixture.

### Out of Scope

- Removing `.shell` from the persisted schema or migrating all shell rows into
  `.terminalAgent`.
- Deleting or modifying user shell session history, transcript files, or
  harness-owned Claude/Codex/Copilot/cmux stores.
- Disabling explicit user-owned shell recovery or explicit
  `autoLaunchResumableOnStartup` behavior.
- Renaming public MCP `group` action fields to `workspace`; compatibility is
  more important than this tranche's UI wording.
- Splitting `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` into smaller
  files.
- Broadly rewriting historical audit logs, completed task docs, old E2E
  artifacts, or old test matrices that record prior behavior as history rather
  than current guidance.

## Completion Criteria

- `WorkbenchBootstrapper().bootstrappedState(from: WorkspaceState())` produces
  one workspace named for unsorted/setup work and no process entries.
- Empty-state bootstrap no longer creates a workspace named `This Mac`.
- Loading or bootstrapping a persisted `.shell` row named `Local Shell` preserves
  its id, executable, arguments, trust, auto-resume, working directory, and run
  history instead of repairing it into a built-in default.
- No source path inserts a `Local Shell` into empty state.
- App startup does not call a built-in default-shell fallback launcher.
- MCP read-only state loading reports empty/no-session truth instead of
  synthesizing a `Local Shell`.
- Existing `.shell` entries are manageable: draft creation, edit/update,
  duplicate, archive, restore, delete request, and boss archive/restore flows do
  not reject them merely because they are `.shell`.
- Explicit user-owned shell auto-resume remains supported through
  `RecoveryPlanner.autoLaunchEligibleEntries` when the app preference is on.
- Scenario verifier still covers a generic shell terminal identity but no longer
  presents `Local Shell` as canonical/default product identity.
- Current product docs no longer recommend a persistent default `Local Shell` or
  describe Workbench as a local shell wrapper.
- Full Swift tests pass with no warnings.
- Scenario verifier passes.
- Packaged and installed app from current source passes live E2E:
  - fresh app-support root has no `Local Shell`, no selected shell, no default
    shell launch action, and setup/onboarding path is available,
  - imported shell fixture appears as a normal managed session with edit/archive
    or delete affordances,
  - reset still enters setup and does not create a shell.

## Code Coverage Requirements

- Update `Tests/OuroWorkbenchCoreTests/WorkbenchBootstrapperTests.swift` to
  cover no-default-shell bootstrap, no-`This Mac` default, and imported shell
  preservation.
- Update or add `Tests/OuroWorkbenchCoreTests/CustomTerminalSessionTests.swift`
  to cover `.shell` draft/update/duplicate/archive/restore behavior.
- Add a focused test for MCP/read-only bootstrap behavior if possible through a
  core helper; otherwise cover the helper introduced to share app/MCP no-shell
  defaults.
- Update scenario matrix tests to cover renamed generic shell identity.
- Do not exclude new code from coverage.

## Open Questions

None for the human. The user's standing mandate is no-human-gates autopilot;
all judgment calls here are resolved by source-grounded reviewer gates.

## Decisions Made

- The correct fix is not a rename from `Local Shell` to another label. The
  built-in shell lifecycle authority itself must be removed.
- `.shell` remains a supported persisted kind for compatibility and runtime
  truth. The issue is special creation/repair/launch authority, not shell
  sessions existing.
- Editing a `.shell` row may go through existing `CustomTerminalSessionFactory`
  mechanics, but bootstrap/load must not silently transmute or repair the row.
  Tests should pin the load behavior and managed-session behavior separately.
- `Unsorted Sessions` is the best default empty workspace name already present
  in `WorkbenchSurfacePolicy.setupWorkspaceName`; it matches setup/import truth
  better than `This Mac`.
- User-owned shells with `autoResume: true` may still auto-launch when the
  explicit startup auto-resume preference is enabled. The banned behavior is
  automatic built-in fallback shell launch.
- MCP must report persisted truth. Read-only consumers should not create or
  normalize a shell that the app would not show.
- Scenario coverage should keep a generic shell identity and optionally an
  imported shell regression case, but not canonize `Local Shell` as the product's normal
  terminal identity.

## Context / References

- `worker/tasks/2026-06-14-1939-ideation-product-center-of-gravity.md`
- `worker/tasks/audit-report.md`
- `worker/tasks/audit-backlog.md`
- `docs/workbench-surface-spec.md`
- `Sources/OuroWorkbenchCore/WorkbenchBootstrapper.swift`
  - `WorkbenchDefaults` defaults to `This Mac` and `includeLocalShell: true`.
  - `BuiltInWorkbenchSessions` owns creation/repair/auto-launch classification.
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`
  - startup currently calls `launchDefaultShellIfNeeded()`.
  - shell management UI is gated by `isCustomSession`.
  - boss archive/restore paths call custom-session archive/restore helpers.
- `Sources/OuroWorkbenchMCP/main.swift`
  - `currentState()` bootstraps read-only state with default defaults.
- `Sources/OuroWorkbenchCore/CustomTerminalSession.swift`
  - `CustomTerminalSessionManager` currently accepts `.terminalAgent` only.
- `Sources/OuroWorkbenchCore/RecoveryPlanner.swift`
  - explicit auto-launch eligibility already covers `.terminalAgent` and
    `.shell`; preserve that behavior.
- `Sources/OuroWorkbenchCore/WorkbenchScenarioMatrix.swift`
- `Sources/OuroWorkbenchScenarioVerifier/main.swift`
- `README.md`, `docs/guide.md`, `docs/roadmap.md`

## Notes

- Cold-read audit found the MCP synthesis risk; include it in implementation,
  not as a deferred cleanup.
- Tinfoil Hat warned that this is cosmetic unless creation, repair, launch, MCP
  synthesis, and manageability are all fixed together.
- Stranger With Candy warned that "custom session" is misleading. Keep API
  renames scoped; behavior and tests matter more than sweeping names in this
  tranche.
- Avoid rewriting old historical artifacts that describe a previous release's
  behavior. Update active docs/specs and generated scenario outputs as needed.

## Progress Log

- 2026-06-14 19:47 Created planning doc from Work Ideator handoff, full-system
  audit addendum, cold-read audit, Tinfoil Hat, and Stranger With Candy passes.
- 2026-06-14 19:47 Planning reviewer gate converged; marked planning approved.
