# Doing: Product Center Of Gravity

**Status**: drafting
**Execution Mode**: direct
**Created**: 2026-06-14 19:47
**Planning**: ./2026-06-14-1947-planning-product-center-of-gravity.md
**Artifacts**: ./2026-06-14-1947-doing-product-center-of-gravity/

## Execution Mode

- **pending**: Awaiting user approval before each unit starts (non-autopilot interactive mode only; autopilot must convert this to `spawn` or `direct` unless a hard exception is present)
- **spawn**: Spawn sub-agent for each unit (parallel/autonomous)
- **direct**: Execute units sequentially in current session (default)

## Objective

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

## Completion Criteria

- [ ] `WorkbenchBootstrapper().bootstrappedState(from: WorkspaceState())` produces one workspace named for unsorted/setup work and no process entries.
- [ ] Empty-state bootstrap no longer creates a workspace named `This Mac`.
- [ ] Loading or bootstrapping a persisted `.shell` row named `Local Shell` preserves its id, executable, arguments, trust, auto-resume, working directory, and run history instead of repairing it into a built-in default.
- [ ] No source path inserts a `Local Shell` into empty state.
- [ ] App startup does not call a built-in default-shell fallback launcher.
- [ ] MCP read-only state loading reports empty/no-session truth instead of synthesizing a `Local Shell`.
- [ ] Existing `.shell` entries are manageable: draft creation, edit/update, duplicate, archive, restore, delete request, and boss archive/restore flows do not reject them merely because they are `.shell`.
- [ ] Explicit user-owned shell auto-resume remains supported through `RecoveryPlanner.autoLaunchEligibleEntries` when the app preference is on.
- [ ] Scenario verifier still covers a generic shell terminal identity but no longer presents `Local Shell` as canonical/default product identity.
- [ ] Current product docs no longer recommend a persistent default `Local Shell` or describe Workbench as a local shell wrapper.
- [ ] Full Swift tests pass with no warnings.
- [ ] Scenario verifier passes.
- [ ] Packaged and installed app from current source passes live E2E:
  - fresh app-support root has no `Local Shell`, no selected shell, no default shell launch action, and setup/onboarding path is available,
  - legacy shell fixture appears as a normal managed session with edit/archive or delete affordances,
  - reset still enters setup and does not create a shell.
- [ ] 100% test coverage on all new code
- [ ] All tests pass
- [ ] No warnings

## Code Coverage Requirements

**MANDATORY: 100% coverage on all new code.**
- No `[ExcludeFromCodeCoverage]` or equivalent on new code
- All branches covered (if/else, switch, try/catch)
- All error paths tested
- Edge cases: null, empty, boundary values

## TDD Requirements

**Strict TDD — no exceptions:**
1. **Tests first**: Write failing tests BEFORE any implementation
2. **Verify failure**: Run tests, confirm they FAIL (red)
3. **Minimal implementation**: Write just enough code to pass
4. **Verify pass**: Run tests, confirm they PASS (green)
5. **Refactor**: Clean up, keep tests green
6. **No skipping**: Never write implementation without failing test first

## Work Units

### Legend
⬜ Not started · 🔄 In progress · ✅ Done · ❌ Blocked

**CRITICAL: Every unit header MUST start with status emoji (⬜ for new units).**

### ⬜ Unit 0: Setup/Research
**What**: Re-read the current branch state and target files before code edits: `Sources/OuroWorkbenchCore/WorkbenchBootstrapper.swift`, `Sources/OuroWorkbenchCore/CustomTerminalSession.swift`, `Sources/OuroWorkbenchCore/RecoveryPlanner.swift`, `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`, `Sources/OuroWorkbenchMCP/main.swift`, scenario files, and active product docs. Record branch, git status, source-of-truth skill status, and exact target list.
**Output**: `2026-06-14-1947-doing-product-center-of-gravity/unit-0-research.md`
**Acceptance**: Artifact records branch, status, target files, test files, and the decisions that `.shell` persists as compatibility state while built-in shell creation/repair/launch authority is removed.

### ⬜ Unit 1a: Bootstrap And MCP Truth — Tests
**What**: Write failing tests for no-default-shell bootstrap and MCP/read-only bootstrap defaults. Update `Tests/OuroWorkbenchCoreTests/WorkbenchBootstrapperTests.swift` and add a core-tested helper file if needed for MCP/app shared defaults.
**Output**: Tests require: default empty bootstrap uses `WorkbenchSurfacePolicy.setupWorkspaceName`, default empty bootstrap has zero `processEntries`, default empty bootstrap does not create `This Mac`, untouched legacy agent scaffold cleanup leaves zero entries instead of a shell, bootstrapping existing agent terminals does not add a shell, and a persisted `.shell` row named `Local Shell` is preserved exactly rather than repaired. Add a test for the helper used by MCP read-only state loading proving it uses no-shell defaults.
**Acceptance**: Focused command `swift test --filter WorkbenchBootstrapperTests` fails before implementation for the new expectations.

### ⬜ Unit 1b: Bootstrap And MCP Truth — Implementation
**What**: Remove normal built-in shell creation/repair authority. Update `WorkbenchDefaults` default project name and `includeLocalShell` posture, remove or neutralize `BuiltInWorkbenchSessions` creation/repair/auto-launch use, update app load fallback to no-shell defaults, and update MCP `currentState()` to use the same no-shell truth through a core helper instead of default shell synthesis.
**Output**: Changes in `Sources/OuroWorkbenchCore/WorkbenchBootstrapper.swift`, any new core helper needed for shared bootstrap defaults, `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`, and `Sources/OuroWorkbenchMCP/main.swift`.
**Acceptance**: `swift test --filter WorkbenchBootstrapperTests` passes and `swift build` succeeds with no warnings.

### ⬜ Unit 1c: Bootstrap And MCP Truth — Coverage & Refactor
**What**: Run focused bootstrap/MCP helper tests and build. Refactor only names or helper boundaries introduced in Unit 1b.
**Output**: Save output to `2026-06-14-1947-doing-product-center-of-gravity/unit-1-bootstrap-mcp.log`.
**Acceptance**: New code paths cover empty bootstrap, setup bootstrap, existing agent terminal, legacy scaffold cleanup, persisted shell preservation, and MCP/app no-shell default helper.

### ⬜ Unit 2a: Managed Shell Sessions — Tests
**What**: Write failing tests proving `.shell` entries are ordinary managed terminal sessions. Update `Tests/OuroWorkbenchCoreTests/CustomTerminalSessionTests.swift`; add focused core tests for a management policy helper if app delete/request guards need extraction.
**Output**: Tests require `CustomTerminalSessionManager.isCustomSession` accepts `.shell`, `draft(from:)` renders direct shell command tokens, `updatedEntry` preserves id/project/archive/attention/owner/pin/friend for shell entries, `duplicateEntry` works for shell entries, `archivedEntry` and `restoredEntry` work for shell entries, and non-terminal `.command` entries still throw `.notCustomSession`. If a deletion guard helper is extracted, test that `.shell` is deletable/manageable while `.command` is not.
**Acceptance**: Focused command `swift test --filter CustomTerminalSessionTests` fails before implementation for shell manageability.

### ⬜ Unit 2b: Managed Shell Sessions — Implementation
**What**: Make `.shell` rows manageable without changing load-time identity. Update `CustomTerminalSessionManager` to accept `.terminalAgent` and `.shell`, produce drafts from direct executable/arguments, and preserve identity fields on update/duplicate/archive/restore. Update app guards and user-facing error text only where necessary so sidebar/header/boss archive/restore paths no longer reject `.shell`.
**Output**: Changes in `Sources/OuroWorkbenchCore/CustomTerminalSession.swift` and narrowly scoped app call-site text/guards in `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`.
**Acceptance**: `swift test --filter CustomTerminalSessionTests` passes and `swift build` succeeds with no warnings.

### ⬜ Unit 2c: Managed Shell Sessions — Coverage & Refactor
**What**: Run focused managed-session tests, any helper tests added in Unit 2a, and build. Refactor only behavior-preserving naming or helper duplication from Unit 2b.
**Output**: Save output to `2026-06-14-1947-doing-product-center-of-gravity/unit-2-managed-shell.log`.
**Acceptance**: Shell draft/update/duplicate/archive/restore and non-terminal rejection branches are covered and green.

### ⬜ Unit 3a: Scenario And Product Docs Drift — Tests
**What**: Write failing tests and validation checks for scenario/docs drift. Update `Tests/OuroWorkbenchCoreTests/WorkbenchScenarioMatrixTests.swift` so the generated matrix contains generic shell coverage but does not use `local_shell` or `Local Shell` as canonical terminal identity. Create an artifact validation script `2026-06-14-1947-doing-product-center-of-gravity/validate-product-center-docs.sh` that greps active docs for forbidden current-guidance phrases.
**Output**: Tests/checks require current scenario rows use a generic/manual shell identity, not `local_shell` / `Local Shell`; active docs `README.md`, `docs/guide.md`, `docs/roadmap.md`, and `docs/workbench-surface-spec.md` do not recommend a default `Local Shell` or call Workbench a local terminal wrapper.
**Acceptance**: `swift test --filter WorkbenchScenarioMatrixTests` or the doc validation script fails before implementation.

### ⬜ Unit 3b: Scenario And Product Docs Drift — Implementation
**What**: Rename scenario generator/matrix shell identity to generic/manual shell while preserving shell coverage. Regenerate scenario docs/TSV if generator output changes. Update active product docs and roadmap lines to reflect boss-led terminal workbench center. Do not rewrite historical completed task artifacts or old E2E evidence logs.
**Output**: Changes in `Sources/OuroWorkbenchCore/WorkbenchScenarioMatrix.swift`, `Sources/OuroWorkbenchScenarioVerifier/main.swift`, generated scenario docs/TSV if required, `README.md`, `docs/guide.md`, `docs/roadmap.md`, and `docs/workbench-surface-spec.md`.
**Acceptance**: Unit 3a tests/checks pass; scenario verifier still has 5,000 rows and zero failures.

### ⬜ Unit 3c: Scenario And Product Docs Drift — Coverage & Refactor
**What**: Run scenario matrix tests, doc validation script, and scenario verifier.
**Output**: Save output to `2026-06-14-1947-doing-product-center-of-gravity/unit-3-scenario-docs.log` and verifier files under `2026-06-14-1947-doing-product-center-of-gravity/scenario-verifier/`.
**Acceptance**: Scenario/docs drift checks are green; shell coverage remains present under the renamed generic/manual identity.

### ⬜ Unit 4: Audit/Spec State Update
**What**: Update `worker/tasks/audit-report.md`, `worker/tasks/audit-backlog.md`, and `docs/workbench-surface-spec.md` to reflect landed behavior and route/close A-011 through A-014 accurately.
**Output**: Docs show A-011 through A-014 fixed or superseded only after tests verify behavior; the spec states shells are ordinary managed sessions and built-in fallback shell creation is absent.
**Acceptance**: `rg -n 'Status\\*\\*: in-progress|default `Local Shell`|persistent `Local Shell` terminal as the first default' worker/tasks/audit-backlog.md docs/workbench-surface-spec.md` finds no stale active/product-guidance line for A-011 through A-014.

### ⬜ Unit 5: Automated Suite Verification
**What**: Run full unit tests and build from repo root.
**Output**: Save output to `2026-06-14-1947-doing-product-center-of-gravity/full-swift-test.log` and `2026-06-14-1947-doing-product-center-of-gravity/swift-build.log`.
**Acceptance**: `swift test` exits 0, `swift build` exits 0, and logs contain no warnings.

### ⬜ Unit 6: Package Install Version Proof
**What**: Package and install the current source app to `$HOME/Applications`, then record source and installed version/build.
**Output**: Save package/install output to `2026-06-14-1947-doing-product-center-of-gravity/package-install.log` and version proof to `2026-06-14-1947-doing-product-center-of-gravity/installed-app-version.txt`.
**Acceptance**: Installed app version/build match current source version/build, and bundle verification succeeds.

### ⬜ Unit 7: Live Fresh/Reset/Legacy Shell E2E
**What**: Create and run `2026-06-14-1947-doing-product-center-of-gravity/validate-product-center-e2e.sh` against the installed app with isolated support roots. Validate three live flows: fresh empty support root, reset from stale `This Mac` + `Local Shell`, and a legacy persisted shell fixture.
**Output**: Save screenshots, app logs, state dumps, and summary to `2026-06-14-1947-doing-product-center-of-gravity/e2e-product-center.md`.
**Acceptance**: Summary contains `PASS product_center_e2e`; fresh and reset states contain no `Local Shell`, no selected shell, and no default-shell launch action; reset consumes setup marker and shows setup/onboarding path; legacy shell fixture remains present with its original executable/trust/auto-resume and appears as a managed session with edit/archive/delete or equivalent affordances in live UI.

## Execution

- **TDD strictly enforced**: tests → red → implement → green → refactor
- Commit after each phase (1a, 1b, 1c)
- Push after each unit complete
- Run full test suite before marking unit done
- **All artifacts**: Save outputs, logs, data to `./2026-06-14-1947-doing-product-center-of-gravity/` directory
- **Fixes/blockers**: Spawn sub-agent immediately — don't ask, just do it
- **Decisions made**: Update docs immediately, commit right away

## Progress Log

- 2026-06-14 19:47 Created from planning doc.
