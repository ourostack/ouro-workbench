# Doing: R3 Workbench Decomposition

**Status**: READY_FOR_EXECUTION
**Execution Mode**: direct
**Created**: 2026-06-30 17:50
**Planning**: ./2026-06-30-1750-planning-r3-workbench-decomposition.md
**Artifacts**: ./2026-06-30-1750-doing-r3-workbench-decomposition/

## Execution Mode

- **pending**: Awaiting user approval before each unit starts (non-autopilot interactive mode only; autopilot must convert this to `spawn` or `direct` unless a hard exception is present)
- **spawn**: Spawn sub-agent for each unit (parallel/autonomous)
- **direct**: Execute units sequentially in current session (default)

## Objective

Extract the next Workbench shell-adjacent slices out of `WorkbenchViews.swift` so command/update/settings behavior is easier to audit and cannot hide inside the giant app view file. Keep the change incremental, behavior-preserving, and covered by the existing Workbench view/view-model characterization tests.

## Upstream Work Items

- Roadmap lane R3 from `/Users/arimendelow/desk/ouro-md/native-app-shell-next-roadmap/task.md`.

## Completion Criteria

- [ ] `WorkbenchViews.swift` loses the extracted command dispatch, command palette, and settings sheet declarations while all call sites continue compiling.
- [ ] New files in `Sources/OuroWorkbenchAppViews/` own those declarations with no new shell-boundary allowlist rows.
- [ ] Existing tests for `DispatchMenuCommand`, `CommandPaletteSheet`, `CommandPaletteSheetInteraction`, `SettingsSheet`, and `SettingsSheetInteraction` pass after the extraction.
- [ ] `scripts/check-shell-boundary.sh` passes.
- [ ] Required Workbench local validation and GitHub CI pass for the PR.
- [ ] PR is merged to `main`, branch/worktree cleanup is complete, and no generated Packages noise remains.
- [ ] 100% test coverage on all new code.
- [ ] All tests pass.
- [ ] No warnings.

## Code Coverage Requirements

**MANDATORY: 100% coverage on all new code.**
- No `[ExcludeFromCodeCoverage]` or equivalent on new code.
- Preserve 100% coverage expectations for every moved declaration by running the existing interaction/snapshot tests that cover those regions.
- Add tests only if extraction changes visibility or creates a new helper that is not already covered by the moved surface tests.
- Do not add coverage exclusions or widen CI allowlists.

## TDD Requirements

**Strict TDD — no exceptions:**
1. **Tests first**: Write failing tests BEFORE any implementation when new behavior is introduced.
2. **Verify failure**: Run tests, confirm they FAIL (red) for new behavior.
3. **Minimal implementation**: Write just enough code to pass.
4. **Verify pass**: Run tests, confirm they PASS (green).
5. **Refactor**: Clean up, keep tests green.
6. **No skipping**: Never write implementation without failing test first. For pure declaration moves, use the existing characterization tests as the executable behavior contract and run them before and after the move.

## Work Units

### Legend
⬜ Not started · 🔄 In progress · ✅ Done · ❌ Blocked

**CRITICAL: Every unit header MUST start with status emoji (⬜ for new units).**

### ✅ Unit 0: Baseline Characterization
**What**: Run focused tests for dispatch, command palette, settings, update tail behavior, and shell boundary before moving code.
**Output**: Baseline logs in `./2026-06-30-1750-doing-r3-workbench-decomposition/`.
**Acceptance**: Baseline either passes or any pre-existing failure is recorded and classified before extraction begins.

### ✅ Unit 1a: Command Dispatch Extraction — Tests
**What**: Run `DispatchMenuCommandTests` against the pre-move command dispatch behavior and save the log.
**Output**: Red/characterization log proving the existing dispatch contract is active before movement.
**Acceptance**: The test target exercises the existing `WorkbenchMenuCommand` and `dispatchMenuCommand` paths before source movement.

### ✅ Unit 1b: Command Dispatch Extraction — Implementation
**What**: Move `WorkbenchMenuCommand` and `dispatchMenuCommand` from `WorkbenchViews.swift` into `Sources/OuroWorkbenchAppViews/WorkbenchMenuCommand.swift`, preserving access and behavior.
**Output**: New command dispatch file; `WorkbenchViews.swift` no longer declares the command enum or dispatch function.
**Acceptance**: `DispatchMenuCommandTests` pass and `rg` shows the declarations in the new file only.

### ✅ Unit 1c: Command Dispatch Extraction — Coverage & Refactor
**What**: Run targeted dispatch tests and build checks; refactor imports or access only if needed.
**Output**: Passing test/build logs.
**Acceptance**: Command dispatch behavior is covered by existing tests with no warnings or shell-boundary allowlist changes.

### ✅ Unit 2a: Command Palette Extraction — Tests
**What**: Run `CommandPaletteSheetTests` and `CommandPaletteSheetInteractionTests` against the pre-move command palette behavior and save logs.
**Output**: Characterization logs proving grouped, empty, filtered, and interaction paths are covered before movement.
**Acceptance**: Existing palette tests exercise the target surface before source movement.

### ✅ Unit 2b: Command Palette Extraction — Implementation
**What**: Move `CommandPaletteSheet` and its private row/section helpers from `WorkbenchViews.swift` into `Sources/OuroWorkbenchAppViews/CommandPaletteSheet.swift`, preserving behavior.
**Output**: New command palette file; `WorkbenchViews.swift` no longer declares `CommandPaletteSheet`.
**Acceptance**: Command palette tests pass and `rg` shows `CommandPaletteSheet` in the new file only.

### ⬜ Unit 2c: Command Palette Extraction — Coverage & Refactor
**What**: Re-run command palette tests and compile checks; adjust imports/access only if compile requires it.
**Output**: Passing logs.
**Acceptance**: Existing command palette coverage remains intact with no UX behavior change.

### ⬜ Unit 3a: Settings Sheet Extraction — Tests
**What**: Run `SettingsSheetTests` and `SettingsSheetInteractionTests` against the pre-move settings sheet behavior and save logs.
**Output**: Characterization logs proving settings render and interaction paths are covered before movement.
**Acceptance**: Existing settings tests exercise the target surface before source movement.

### ⬜ Unit 3b: Settings Sheet Extraction — Implementation
**What**: Move `SettingsSheet` and `SettingsSection` from `WorkbenchViews.swift` into `Sources/OuroWorkbenchAppViews/SettingsSheet.swift`, preserving bindings and update panel embedding.
**Output**: New settings file; `WorkbenchViews.swift` no longer declares the settings sheet types.
**Acceptance**: Settings tests pass and `rg` shows settings declarations in the new file only.

### ⬜ Unit 3c: Settings Sheet Extraction — Coverage & Refactor
**What**: Re-run settings tests and compile checks; adjust imports/access only if compile requires it.
**Output**: Passing logs.
**Acceptance**: Existing settings coverage remains intact with no UX behavior change.

### ⬜ Unit 4: Full Local Validation
**What**: Run shell boundary validation, focused test suite, full `swift test`, and `swift build`.
**Output**: Validation logs in the artifacts directory.
**Acceptance**: All required local validation passes without warnings; `git status` has no generated package/dependency noise.

### ⬜ Unit 5: Review, PR, CI, Merge, Cleanup
**What**: Run cold self-review/pre-merge sanity review, open/update PR, wait for CI, merge when green, verify `main`, and clean branch/worktree.
**Output**: PR URL, CI evidence, merge commit, cleanup evidence.
**Acceptance**: PR is merged to `main`, CI is green, no stale branch/worktree from this run remains, and no continuation item in this lane is ready inside current scope.

## Execution

- **TDD strictly enforced**: tests/characterization -> move -> green -> refactor.
- Commit after each phase when there is a logical code or doc change.
- Push after each unit complete.
- Run full test suite before marking implementation done.
- **All artifacts**: Save outputs, logs, data to `./2026-06-30-1750-doing-r3-workbench-decomposition/`.
- **Fixes/blockers**: Spawn or emulate fresh reviewer gates immediately; do not ask unless a true human-only credential/capability or unrecoverable destructive shared-production action appears.
- **Decisions made**: Update docs immediately, commit right away.

## Progress Log

- 2026-06-30 17:50 Created from planning doc after planning reviewer gate convergence.
- 2026-06-30 17:50 Doing conversion review converged: granularity, validation, ambiguity, quality, and scrutiny probes found no BLOCKER/MAJOR findings.
- 2026-06-30 17:59 Unit 0 complete: baseline dispatch, command palette, settings, release/update/diagnostics tail tests, and shell boundary validation passed; log saved to `unit-0-baseline.log`.
- 2026-06-30 17:59 Unit 1a complete: `DispatchMenuCommandTests` passed pre-move in `unit-0-baseline.log` with 38 tests and zero failures.
- 2026-06-30 18:02 Unit 1b complete: moved menu command enum, notification, and dispatch function to `Sources/OuroWorkbenchAppViews/WorkbenchMenuCommand.swift`; `DispatchMenuCommandTests` passed with 38 tests and zero failures.
- 2026-06-30 18:02 Unit 1c complete: post-extraction `DispatchMenuCommandTests`, `swift build`, and `scripts/check-shell-boundary.sh` passed.
- 2026-06-30 18:02 Unit 2a complete: `CommandPaletteSheetTests` and `CommandPaletteSheetInteractionTests` passed pre-move in `unit-0-baseline.log` with 18 tests and zero failures.
- 2026-06-30 18:05 Unit 2b complete: moved `CommandPaletteSheet` into `Sources/OuroWorkbenchAppViews/CommandPaletteSheet.swift`; palette tests passed with 18 tests and zero failures.
