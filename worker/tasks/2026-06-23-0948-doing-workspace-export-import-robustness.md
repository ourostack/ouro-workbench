# Doing: Workspace export/import robustness (3 fixes)

- Branch: `fix/workspace-export-import-robustness` (off `origin/main` @ `5f93d5e`)
- Execution Mode: direct
- Artifacts: `worker/tasks/2026-06-23-0948-doing-workspace-export-import-robustness/`
- Status: in-progress
- DO NOT MERGE/PR — stop after committed + pushed; parent cold-reviews + merges.

## Context

Three workspace export/import robustness fixes in the native macOS SwiftUI app
(`Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` + `Sources/OuroWorkbenchCore`).
Line numbers are STALE (concurrent refactor) — re-locate by symbol/grep.

Re-located sites (at HEAD `5f93d5e`):
- FIX 1: `presentSaveWorkspacePanel()` — the lone export `try data.write(to: url)`
  (one call; the spec's "~2" was a stale estimate — confirmed via repo-wide grep:
  the only non-atomic workspace-export write is in this function).
- FIX 2: `openWorkspaceConfig(config:configDirectory:loader:)` import-apply — dedups
  by `(projectId, name)`, lumps "already present" into `skippedNames`.
  `WorkbenchImportApplyResult` lives in the App target (not Core, despite spec text).
- FIX 3: `openWorkspaceConfig(at:)` — only `configFileMissing` calls
  `forgetRecentWorkspace`. `malformedJSON` / `noTerminals` / generic `catch` do not.
  `WorkbenchWorkspaceConfigError` (Core) has 3 cases: `configFileMissing`,
  `malformedJSON` (also covers unreadable-file), `noTerminals`.

Test pattern: source-pin tests read the App source as text and assert on slices
(template: `Tests/OuroWorkbenchCoreTests/ImportPersistenceHonestyWiringTests.swift`).
Pure Core logic gets exhaustive unit tests + 100% line/region. Allowlist stays at 2.

## Units

### ✅ U1 — FIX 1: atomic workspace export write (MED, data loss)
- **What:** Add `options: [.atomic]` to the export `write(to:)` in
  `presentSaveWorkspacePanel()`. Atomic write goes to a temp file + renames, so a
  partial/interrupted write never clobbers the operator's prior workspace file.
- **Test (Xa):** New source-pin
  `Tests/OuroWorkbenchCoreTests/WorkspaceExportImportRobustnessWiringTests.swift`
  asserting EVERY `write(to:` inside the export function uses `.atomic` (robust to
  1-or-2 calls), and that no non-atomic `write(to:` survives in that slice.
- **Impl (Xb):** add `options: [.atomic]`.
- **Acceptance:** test red → green; `swift build`/`swift test` clean.

### ✅ U2 — FIX 2: surface "already present" import skips (LOW)
- **What:** Distinguish "already present (unchanged)" from genuine error-skips in
  the import-apply path. Add additive `alreadyPresentCount` to
  `WorkbenchImportApplyResult`; count `(projectId,name)` matches separately from
  error-skips; surface as "N already present" in the `detail` summary.
- **Inverse-bug watch:** must NOT start updating matched terminals (deferred
  decision) — only surface the count; a genuinely-new terminal still imports.
- **Test (Xa):** source-pin that the import-apply separates already-present from
  error-skips, that `WorkbenchImportApplyResult` carries `alreadyPresentCount`, and
  that `detail` surfaces "already present". Keep the inverse-bug pin: matched
  terminals are still `continue`d (not updated).
- **Impl (Xb):** additive field + count + summary text.
- **Acceptance:** test red → green; build/test clean.

### ⬜ U3 — FIX 3: prune broken recents on all structural errors (LOW)
- **What:** Extract a pure Core decision
  `WorkbenchRecentWorkspacePruning.shouldForgetRecent(after:)` — prune on
  structural errors (`configFileMissing`, `malformedJSON`, `noTerminals`), KEEP on
  transient/unknown (the generic `catch` / non-config errors). Wire all three
  `WorkbenchWorkspaceConfigError` branches in `openWorkspaceConfig(at:)` to call
  `forgetRecentWorkspace` via the decision; leave the generic `catch` un-pruned.
- **Inverse-bug watch:** must NOT prune a recent on a TRANSIENT/recoverable error —
  only structural ones.
- **Test (Xa):** exhaustive Core unit test on the pure decision (prune on
  missing/malformed/noTerminals; keep on transient). Source-pin that the additional
  error branches now route through the decision + forget the recent, and that the
  generic `catch` does NOT prune.
- **Impl (Xb):** new Core file + wire branches. 100% line/region; allowlist stays 2.
- **Acceptance:** test red → green; `swift build`/`swift test` clean;
  `Scripts/check-coverage.sh` passes; allowlist unchanged at 2.

## Verify (final gate)
- `swift build`/`swift test` with `-Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`; 0 failures.
- `Scripts/check-coverage.sh` — pure Workbench logic 100% line+region; allowlist at 2.

## Completion Criteria
- [x] U1: both/all export writes atomic (confirmed via grep + source-pin). Repo-wide grep confirms exactly ONE workspace-export write (`presentSaveWorkspacePanel`); now `.write(to: url, options: [.atomic])`.
- [x] U2: already-present count surfaced distinctly from error-skips; matched terminals NOT updated. Added `WorkbenchImportApplyResult.alreadyPresentCount` (additive); `detail` shows "N already present"; loop increments tally + still `continue`s matched terminals.
- [ ] U3: recents pruned on missing/malformed/noTerminals; kept on transient; pure decision + exhaustive test.
- [ ] Coverage 100% line+region on new Core logic; allowlist unchanged at 2.
- [ ] 3 commits (one per fix), pushed. No merge/PR.

## Progress log

- 2026-06-23 09:53 U1 (FIX 1) complete: source-pin red→green, added `options: [.atomic]` to the lone export write in `presentSaveWorkspacePanel()`. Build clean under `-warnings-as-errors -strict-concurrency=complete`. Commits: f6cdd03 (test), e8ed00f (impl).
- 2026-06-23 09:58 U2 (FIX 2) complete: 3 source-pins red→green (verified red with impl stashed). Added additive `alreadyPresentCount`, tallied `(projectId,name)` matches separately from error-skips, surfaced "N already present" in `detail` + action-log; matched terminals still `continue` (inverse-bug guard pinned). Build clean. Commits: f2711cd (test), e8eedee (impl).
