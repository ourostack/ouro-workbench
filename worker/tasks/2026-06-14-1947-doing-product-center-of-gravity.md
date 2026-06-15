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
- [ ] Scenario verifier still covers a generic shell terminal identity as `user_shell` / `User Shell` with fixture `kind == .shell`, but no longer presents `Local Shell` as canonical/default product identity.
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
**What**: Re-read the current branch state and target files before code edits: `Sources/OuroWorkbenchCore/WorkbenchBootstrapper.swift`, `Sources/OuroWorkbenchCore/CustomTerminalSession.swift`, `Sources/OuroWorkbenchCore/RecoveryPlanner.swift`, `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`, `Sources/OuroWorkbenchMCP/main.swift`, `Sources/OuroWorkbenchCore/WorkbenchScenarioMatrix.swift`, `Sources/OuroWorkbenchScenarioVerifier/main.swift`, `README.md`, `docs/guide.md`, `docs/roadmap.md`, and `docs/workbench-surface-spec.md`. Record branch, git status, source-of-truth skill status, and exact target list.
**Output**: `2026-06-14-1947-doing-product-center-of-gravity/unit-0-research.md`
**Acceptance**: Artifact records branch, status, target files, test files, and the decisions that `.shell` persists as compatibility state while built-in shell creation/repair/launch authority is removed.

### ⬜ Unit 1a: Bootstrap And MCP Truth — Tests
**What**: Write failing tests for no-default-shell bootstrap and MCP/read-only bootstrap defaults. Update `Tests/OuroWorkbenchCoreTests/WorkbenchBootstrapperTests.swift` and `Tests/OuroWorkbenchCoreTests/WorkbenchLaunchDiagnosticsTests.swift`. Use `WorkbenchDefaults()` as the shared app/MCP no-shell contract; no new helper is planned for this pass.
**Output**: Tests require: default empty bootstrap uses `WorkbenchSurfacePolicy.setupWorkspaceName`, default empty bootstrap has zero `processEntries`, default empty bootstrap does not create `This Mac`, untouched legacy agent scaffold cleanup leaves zero entries instead of a shell, bootstrapping existing agent terminals does not add a shell, and a persisted `.shell` row named `Local Shell` is preserved exactly rather than repaired. Add a test proving `WorkbenchDefaults()` carries no-shell defaults for MCP read-only state loading. Add or update launch-diagnostics coverage proving `--app-support-root` remains parsed for deterministic app/MCP runtime isolation.
**Acceptance**: Run `swift test --filter WorkbenchBootstrapperTests` and `swift test --filter WorkbenchLaunchDiagnosticsTests`; every newly added bootstrap/defaults/runtime-isolation check fails before implementation, or the Unit 1 artifact records that a specific check already passed at HEAD.

### ⬜ Unit 1b: Bootstrap And MCP Truth — Implementation
**What**: Delete or bypass every call path that creates, repairs, selects, or launches `BuiltInWorkbenchSessions.localShell` during empty bootstrap, app fallback loading, startup fallback launch, and MCP state loading. Update `WorkbenchDefaults` default project name and default shell posture, update app load fallback to `WorkbenchDefaults()` no-shell truth, and make MCP `currentState()` rely on that same no-shell default state instead of default shell synthesis. Add MCP support for the existing `--app-support-root PATH` runtime-isolation flag by parsing `WorkbenchLaunchDiagnostics` in `Sources/OuroWorkbenchMCP/main.swift` and constructing `WorkbenchPaths(rootURL:)` when provided.
**Output**: Changes in `Sources/OuroWorkbenchCore/WorkbenchBootstrapper.swift`, `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`, and `Sources/OuroWorkbenchMCP/main.swift`.
**Acceptance**: `swift test --filter WorkbenchBootstrapperTests` passes and `swift build` succeeds with no warnings.

### ⬜ Unit 1c: Bootstrap And MCP Truth — Coverage & Refactor
**What**: Run focused bootstrap/runtime-isolation tests, direct MCP JSON-RPC empty-state proof, and build. Refactor only names or helper boundaries introduced in Unit 1b.
**Output**: Save output to `2026-06-14-1947-doing-product-center-of-gravity/unit-1-bootstrap-mcp.log`.
**Acceptance**: `swift test --filter WorkbenchBootstrapperTests`, `swift test --filter WorkbenchLaunchDiagnosticsTests`, `mcp_root="$(mktemp -d "${TMPDIR:-/tmp}/ouro-workbench-mcp-empty.XXXXXX")"; printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"workbench_sessions","arguments":{"format":"json"}}}' | swift run OuroWorkbenchMCP --app-support-root "$mcp_root"` and `swift build` all exit 0. MCP output contains `"sessions":[]`, does not contain `Local Shell`, and proves `--app-support-root` isolation is honored.

### ⬜ Unit 2a: Managed Shell Sessions — Tests
**What**: Write failing tests proving `.shell` entries are ordinary managed terminal sessions. Update `Tests/OuroWorkbenchCoreTests/CustomTerminalSessionTests.swift` and `Tests/OuroWorkbenchCoreTests/BossWorkbenchActionAuthorizerTests.swift`. Do not extract a new delete/request helper unless compilation of the narrow app call-site changes requires it.
**Output**: Tests require `CustomTerminalSessionManager.isCustomSession` accepts `.shell`, `draft(from:)` renders direct shell command tokens, `updatedEntry` preserves id/project/archive/attention/owner/pin/friend/kind for shell entries, `duplicateEntry` works for shell entries and preserves shell kind, `archivedEntry` and `restoredEntry` work for shell entries, and non-terminal `.command` entries still throw `.notCustomSession`. Boss action tests require trusted `.shell` entries can be authorized for archive and restore while untrusted `.shell` entries remain denied.
**Acceptance**: Run `swift test --filter CustomTerminalSessionTests` and `swift test --filter BossWorkbenchActionAuthorizerTests`; every newly added managed-shell/boss-action check fails before implementation, or the Unit 2 artifact records that a specific check already passed at HEAD.

### ⬜ Unit 2b: Managed Shell Sessions — Implementation
**What**: Make `.shell` rows manageable without changing load-time identity. Update `CustomTerminalSessionManager` to accept `.terminalAgent` and `.shell`, produce drafts from direct executable/arguments, and preserve identity fields on update/duplicate/archive/restore. Update every guard/error path that currently rejects `.shell` because it is not `.terminalAgent`; leave unrelated UI copy unchanged.
**Output**: Changes in `Sources/OuroWorkbenchCore/CustomTerminalSession.swift` and only call sites in `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` that gate create/edit/duplicate/archive/restore/delete behavior for terminal session entries.
**Acceptance**: `swift test --filter CustomTerminalSessionTests` passes and `swift build` succeeds with no warnings.

### ⬜ Unit 2c: Managed Shell Sessions — Coverage & Refactor
**What**: Run focused managed-session and boss-action tests plus build. Refactor only behavior-preserving naming or helper duplication from Unit 2b.
**Output**: Save output to `2026-06-14-1947-doing-product-center-of-gravity/unit-2-managed-shell.log`.
**Acceptance**: `swift test --filter CustomTerminalSessionTests`, `swift test --filter BossWorkbenchActionAuthorizerTests`, and `swift build` exit 0. Shell draft/update/duplicate/archive/restore, boss archive/restore authorization, and non-terminal rejection branches are covered and green.

### ⬜ Unit 3a: Scenario And Product Docs Drift — Tests
**What**: Write failing tests and validation checks for scenario/docs drift. Update `Tests/OuroWorkbenchCoreTests/WorkbenchScenarioMatrixTests.swift` so the generated matrix contains generic shell coverage under row key `user_shell`, display name `User Shell`, and fixture `kind == .shell`, but does not use `local_shell` or `Local Shell` as canonical terminal identity. Create an artifact validation script `2026-06-14-1947-doing-product-center-of-gravity/validate-product-center-docs.sh` that greps active docs for forbidden current-guidance phrases.
**Output**: Tests/checks require current scenario rows use `user_shell` / `User Shell` with shell fixtures, not `local_shell` / `Local Shell`; active docs `README.md`, `docs/guide.md`, `docs/roadmap.md`, and `docs/workbench-surface-spec.md` do not recommend a default `Local Shell` or call Workbench a local terminal wrapper.
**Acceptance**: Both `swift test --filter WorkbenchScenarioMatrixTests` and `2026-06-14-1947-doing-product-center-of-gravity/validate-product-center-docs.sh` are run; every newly added scenario/doc check fails before implementation, or the artifact records why a specific check already passes at HEAD.

### ⬜ Unit 3b: Scenario And Product Docs Drift — Implementation
**What**: Rename scenario generator/matrix shell identity to `user_shell` / `User Shell` while preserving fixture `kind == .shell`. After changing the generator, run `scripts/generate-workbench-5000-matrix.rb` and commit generated docs/TSV only when their diff changes. Update current product docs and roadmap lines in `README.md`, `docs/guide.md`, `docs/roadmap.md`, and `docs/workbench-surface-spec.md` to reflect boss-led terminal workbench center. Do not rewrite historical completed task artifacts or old E2E evidence logs.
**Output**: Changes in `Sources/OuroWorkbenchCore/WorkbenchScenarioMatrix.swift`, `Sources/OuroWorkbenchScenarioVerifier/main.swift`, generated scenario docs/TSV when their diff changes, `README.md`, `docs/guide.md`, `docs/roadmap.md`, and `docs/workbench-surface-spec.md`.
**Acceptance**: Unit 3a tests/checks pass; scenario verifier still has 5,000 rows and zero failures.

### ⬜ Unit 3c: Scenario And Product Docs Drift — Coverage & Refactor
**What**: Run scenario matrix tests, doc validation script, and scenario verifier.
**Output**: Save output to `2026-06-14-1947-doing-product-center-of-gravity/unit-3-scenario-docs.log` and verifier files under `2026-06-14-1947-doing-product-center-of-gravity/scenario-verifier/`.
**Acceptance**: `swift test --filter WorkbenchScenarioMatrixTests`, `2026-06-14-1947-doing-product-center-of-gravity/validate-product-center-docs.sh`, and `swift run OuroWorkbenchScenarioVerifier --out 2026-06-14-1947-doing-product-center-of-gravity/scenario-verifier` exit 0. Scenario/docs drift checks are green; shell coverage remains present under `user_shell` / `User Shell` with fixture `kind == .shell`.

### ⬜ Unit 4: Audit/Spec State Update
**What**: Update `worker/tasks/audit-report.md`, `worker/tasks/audit-backlog.md`, and `docs/workbench-surface-spec.md` to reflect landed behavior and route/close A-011 through A-014 accurately.
**Output**: Docs show A-011 through A-014 fixed or superseded only after tests verify behavior; the spec states shells are ordinary managed sessions and built-in fallback shell creation is absent.
**Acceptance**: `if rg -n 'Status\\*\\*: in-progress|default Local Shell|persistent Local Shell terminal as the first default' worker/tasks/audit-backlog.md docs/workbench-surface-spec.md; then exit 1; fi` exits 0.

### ⬜ Unit 5: Automated Suite Verification
**What**: Run full unit tests and build from repo root.
**Output**: Save output to `2026-06-14-1947-doing-product-center-of-gravity/full-swift-test.log` and `2026-06-14-1947-doing-product-center-of-gravity/swift-build.log`.
**Acceptance**: `swift test` exits 0, `swift build` exits 0, and logs contain no warnings.

### ⬜ Unit 6: Package Install Version Proof
**What**: Record `git rev-parse HEAD` and `git status --short`, run `scripts/package-app.sh`, then `scripts/install-app.sh --install-dir "$HOME/Applications"`, then `scripts/verify-app-bundle.sh "$HOME/Applications/Ouro Workbench.app"`. Record `CFBundleShortVersionString`, `CFBundleVersion`, and `shasum -a 256` from both `dist/Ouro Workbench.app/Contents/MacOS/OuroWorkbench` and `$HOME/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbench`.
**Output**: Save package/install output to `2026-06-14-1947-doing-product-center-of-gravity/package-install.log` and version proof to `2026-06-14-1947-doing-product-center-of-gravity/installed-app-version.txt`.
**Acceptance**: Built bundle version/build and installed bundle version/build are exactly equal, dist/installed executable hashes are exactly equal, recorded git SHA matches HEAD at package time, and bundle verification succeeds.

### ⬜ Unit 7a: Live E2E Script And Fixtures
**What**: Create `2026-06-14-1947-doing-product-center-of-gravity/validate-product-center-e2e.sh` with flow selectors `fresh`, `reset`, `legacy_shell`, `all`, and `verify`, plus isolated app-support roots for fresh, reset, and legacy-shell flows. The script must start the installed app, capture screenshots, dump `workspace-state.json` through `plutil -p`, and write separate summary sections for `fresh`, `reset`, and `legacy_shell`.
**Output**: Validation script plus seeded fixture JSON files under `2026-06-14-1947-doing-product-center-of-gravity/e2e-fixtures/`.
**Acceptance**: Script is executable and `shellcheck` is run if available; otherwise `zsh -n` passes. The fixture JSON includes stale reset state with `This Mac` + `Local Shell` and legacy shell state with a non-default executable/trust/auto-resume combination.

### ⬜ Unit 7b: Live Fresh And Reset E2E
**What**: Run `2026-06-14-1947-doing-product-center-of-gravity/validate-product-center-e2e.sh fresh reset` against the installed app. The reset flow must first launch the installed app against stale `This Mac` + `Local Shell` state, then invoke the installed app executable with `--factory-reset-for-e2e --app-support-root "$reset_root"`, then relaunch the app against the same reset root.
**Output**: Save fresh/reset screenshots, app logs, state dumps, and summary sections to `2026-06-14-1947-doing-product-center-of-gravity/e2e-product-center.md`.
**Acceptance**: Summary contains `PASS fresh` and `PASS reset`; fresh and reset states contain no `Local Shell`, no selected shell, and no default-shell launch action; reset consumes setup marker and visible screenshot shows setup workspace/onboarding UI.

### ⬜ Unit 7c: Live Legacy Shell E2E
**What**: Run `2026-06-14-1947-doing-product-center-of-gravity/validate-product-center-e2e.sh legacy_shell` against the installed app.
**Output**: Save legacy shell screenshot, app log, state dump, and summary section to `2026-06-14-1947-doing-product-center-of-gravity/e2e-product-center.md`.
**Acceptance**: Summary contains `PASS legacy_shell`; legacy shell fixture remains present with its original executable, arguments, trust, auto-resume, working directory, and id; live UI screenshot shows visible Edit Session, Archive Session, and Delete Session actions, or the artifact records matching accessibility/menu text for those exact actions; the flow performs archive, restore, and delete-confirm actions against a throwaway duplicate or copied fixture state and proves none reject `.shell`.

### ⬜ Unit 7d: Live E2E Evidence Consolidation
**What**: Run `2026-06-14-1947-doing-product-center-of-gravity/validate-product-center-e2e.sh verify`, verify all Unit 7 summaries, screenshots, logs, and state dumps exist, and update completion criteria with exact evidence paths.
**Output**: Final `2026-06-14-1947-doing-product-center-of-gravity/e2e-product-center.md` summary.
**Acceptance**: Summary contains `PASS product_center_e2e`, `PASS fresh`, `PASS reset`, and `PASS legacy_shell`, with paths to every screenshot and state dump.

## Execution

- **TDD strictly enforced**: tests → red → implement → green → refactor
- Commit red-test units after red proof is captured; those commits may contain intentionally failing focused tests and are immediately followed by the matching implementation unit.
- Commit green implementation and coverage/refactor units after their focused tests and build pass.
- Run the full suite before marking verification units and the whole doing doc complete.
- **All artifacts**: Save outputs, logs, data to `./2026-06-14-1947-doing-product-center-of-gravity/` directory
- **Fixes/blockers**: Spawn sub-agent immediately — don't ask, just do it
- **Decisions made**: Update docs immediately, commit right away

## Progress Log

- 2026-06-14 19:47 Created from planning doc.
