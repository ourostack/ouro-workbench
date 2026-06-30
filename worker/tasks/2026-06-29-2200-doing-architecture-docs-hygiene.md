# Doing: Workbench Architecture / Docs Hygiene

**Status**: in-progress
**Execution Mode**: direct
**Created**: 2026-06-29 22:00
**Planning**: ./2026-06-29-2200-planning-architecture-docs-hygiene.md
**Artifacts**: ./2026-06-29-2200-doing-architecture-docs-hygiene/

## Execution Mode

- **pending**: Awaiting user approval before each unit starts (non-autopilot interactive mode only; autopilot must convert this to `spawn` or `direct` unless a hard exception is present)
- **spawn**: Spawn sub-agent for each unit (parallel/autonomous)
- **direct**: Execute units sequentially in current session (default)

## Objective
Reduce Workbench app-layer bulk around shell-adjacent UI and make current architecture/docs sources easy for future agents to find without rereading historical planning artifacts.

## Upstream Work Items
- A-006: Continue Workbench View/ViewModel Decomposition
- A-010: Refresh Workbench Architecture Docs For The Shell Split
- A-027: Clean Up Or Archive Stale Workbench Planning/Doing Docs
- A-038: Add A Cross-Repo "Normative Docs" Index

## Completion Criteria
- [x] A-006 has at least one narrow shell-adjacent view/view-model decomposition committed.
- [x] A-010 architecture docs describe shell ownership and dependency direction.
- [x] A-027 Workbench docs index distinguishes current normative docs from historical planning artifacts.
- [x] A-038 has Workbench index coverage and minimal cross-repo index updates where safe.
- [x] Stale `Set Up Workbench` and `⌘?` drift in touched Workbench docs/comments is corrected.
- [x] 100% test coverage on all new code.
- [x] All tests pass.
- [x] No warnings.

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

### ✅ Unit 0: Setup/Research
**What**: Read audit rows, repo instructions, architecture docs, app-view bulk targets, and docs inventory.
**Output**: Evidence captured in the plan/doing docs and implementation choices.
**Acceptance**: Audit item IDs, branch/worktree, source docs, and validation targets are recorded.

### ✅ Unit 1: Shell-Adjacent View Extraction
**What**: Move the shortcut help sheet out of `WorkbenchViews.swift` into its own app-view module without changing behavior.
**Output**: New Swift file plus reduced `WorkbenchViews.swift` size.
**Acceptance**: Shortcut help tests still pass and the new file compiles without warnings.

### ✅ Unit 2: Workbench Normative Docs Index
**What**: Refresh `docs/architecture.md`, add `docs/INDEX.md`, and fix stale setup/shortcut naming in touched Workbench docs/comments.
**Output**: Architecture docs and Workbench docs index.
**Acceptance**: Index classifies normative docs, product docs, runbooks/control decks, and historical planning artifacts.

### ✅ Unit 3: Minimal Cross-Repo Docs Indexes
**What**: Add small `docs/INDEX.md` files to Ouro MD and shared shell if safe and docs-only.
**Output**: Cross-repo index commits or documented no-op evidence.
**Acceptance**: Each touched repo has a current-docs entry point without changing implementation scope.

### ✅ Unit 4: Validation and Review
**What**: Run Swift/tests/docs validation, shell boundary checks, and a cold review of the diff against A-006/A-010/A-027/A-038.
**Output**: Validation logs in the artifacts directory and final review notes.
**Acceptance**: Relevant tests pass or blockers are recorded with exact commands/output.

### 🔄 Unit 5: PR/Merge/Cleanup
**What**: Push branches, open PRs, merge where safe, and clean terminal worktrees if terminal.
**Output**: PR/merge evidence or residual blocker evidence.
**Acceptance**: Branch state, PR URLs, merge/CI status, and any remaining blockers are recorded.

## Execution
- **TDD strictly enforced**: tests → red → implement → green → refactor
- Commit after each phase (1a, 1b, 1c)
- Push after each unit complete
- Run full test suite before marking unit done
- **All artifacts**: Save outputs, logs, data to `./2026-06-29-2200-doing-architecture-docs-hygiene/` directory
- **Fixes/blockers**: Spawn sub-agent immediately — don't ask, just do it
- **Decisions made**: Update docs immediately, commit right away

## Progress Log
- 2026-06-29 22:00 Created from planning doc.
- 2026-06-29 22:00 Unit 0 complete: read audit rows A-006/A-010/A-027/A-038, Workbench AGENTS/README/architecture docs, docs inventory, and app-layer bulk targets.
- 2026-06-29 22:04 Unit 1 complete: extracted `ShortcutHelpSheet` into its own shell-adjacent app-view module, corrected the shortcut comment, and validated with `swift test --filter ShortcutHelpSheet` (5 tests, 0 failures).
- 2026-06-29 22:07 Unit 2 complete: refreshed architecture shell-boundary docs, added `docs/INDEX.md`, fixed current-doc setup naming drift, and verified index links plus stale-string checks.
- 2026-06-29 22:10 Unit 3 complete: added minimal docs indexes in Ouro MD (`01dbab5`) and shared shell (`2a5bedb`) on `worker/docs-index` branches.
- 2026-06-29 22:12 Unit 4 complete: full `swift test` passed (4,476 tests, 1 skipped, 0 failures), shell boundary selftest/scan passed, shell dependency freshness passed, and cold diff review found no A-006/A-010/A-027/A-038 gaps.
- 2026-06-29 22:27 Unit 5 CI repair: Workbench PR #415 failed release freshness because app/release-affecting files changed at version `0.1.232`, and failed shell dependency freshness because `Package.resolved` still pinned `ouro-native-apple-app-shell@9f1db0b`. Bumped Workbench to `0.1.233`, added the changelog entry, and refreshed the shared shell pin to `e4f1d9f`. Local repair gates passed: `scripts/verify-version-contract.sh`, `scripts/release-policy.sh freshness --mode pr --base-ref origin/main`, `scripts/check-shell-dependency.sh`, `scripts/check-shell-boundary.sh`, `scripts/release-policy.sh selftest-paths`, `scripts/release-policy.sh selftest-package-guards`, `swift test --filter WorkbenchAppSourceRetargetTests`, `swift test --filter ShortcutHelpSheet`, and full `swift test` (4,476 tests, 1 skipped, 0 failures).
