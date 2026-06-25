# Slice ②a Doing-Doc — Fresh Unbiased Review-Gate Findings

Run as the autonomous equivalent of human signoff (same gate used for Slice ①). A fresh reviewer was asked to adversarially verify 7 claims against real source; remaining points were verified directly against the repo. Verdict: **NEEDS FIXES → fixed → SAFE TO EXECUTE.**

## 1. Schema-bump blast radius — DISCREPANCY (FIXED)
The doc originally listed THREE literal-`1` tests to change to `2`. Re-validation against source corrected this to **TWO changes + one deliberate non-change**:
- CHANGE → 2: `DegradedReadTests.swift:72` (asserts `currentSchemaVersion` constant).
- CHANGE → 2: `WorkbenchStoreTests.swift:15` (`testMissingStateFileLoadsEmptyWorkspace` — missing file ⇒ fresh `WorkspaceState()` ⇒ memberwise default = current = 2).
- STAY 1: `PaneLayoutStateTests.swift:73` — decodes input JSON `"schemaVersion": 1` (line 58) and asserts the value. `WorkspaceState.init(from:)` (`WorkspaceModels.swift:727`) **decodes & PRESERVES** the input version (does not reset to current), so it stays 1 under v2. Changing it to 2 would have broken the test.

Full Tests/ sweep confirmed every other `schemaVersion` occurrence is bump-safe: input-only JSON with no version assertion (`AutomaticBossDefaultsTests:16/25`, `WorkspaceStateProseLogTests:39`, `BossInboxDecisionTests:84/661`, `WorkspaceModelsTests:188`, `WorkbenchVisibilityTests:420/514`) or via the `currentSchemaVersion` constant ± offset (`WorkbenchStoreTests` older/newer/equal/zero; `DegradedReadTests` tooNew).

## 2. Backcompat gate — CONFIRMED
`WorkbenchStore.load` (`WorkbenchStore.swift:128`): `guard state.schemaVersion <= WorkspaceState.currentSchemaVersion`. Accepts older/equal, rejects only newer. No other version-literal gate; `DegradedRead.swift:48` derives `supportedVersion` from the constant. Bumping to 2 keeps v1 loading; only v3+ quarantines.

## 3. Additive / non-breaking — CONFIRMED
210 `ProcessEntry(...)` + 191 `WorkspaceState(...)` call sites across Sources/ + Tests/. ZERO use a trailing closure. Swift initializers require argument labels, so a new defaulted parameter (`tabNameOverride`, `workspaces`) is purely additive and breaks no call site, regardless of position. Matches the file's established additive pattern (`discoveredHarness`, `isInFlight`, `detailLayout`).

## 4. CodingKeys / decode — CONFIRMED
`decodeLenientArray` helper exists (`FailableDecodable.swift:25`). `WorkspaceState` has explicit `CodingKeys` that deliberately EXCLUDES `decodeReport`; adding `workspaces` there is consistent. `ProcessEntry` has an explicit `init(from:)` using `decodeIfPresent` — `tabNameOverride` follows the same pattern.

## 5. App wiring anchor — CONFIRMED (and strengthened)
Bootstrap load-success path: `loaded = store.load()` (:19930) → `state = startupRecoveryReconciler.reconcile(bootstrapper.bootstrappedState(from: loaded))` (:19942) → `applyCollapsedChromeMigrationIfNeeded()` (:19943) → `applyAutomaticBossDefaultsMigrationIfNeeded()` (:19944). Add `state.migrateToWorkspaceStructure()` after :19944.
KEY: both `WorkbenchBootstrapper.bootstrappedState` and `StartupRecoveryReconciler.reconcile` do `var next = state` then mutate-and-return — NOT a memberwise rebuild — so the new `workspaces` collection passes through bootstrap untouched. No drop risk.

## 6. Coverage feasibility — CONFIRMED
No structurally-dead arm in the planned new code. The DA2 Mirror invariant test and every migration branch (unmapped-active / already-mapped / empty / archived-excluded / append-to-existing) are reachable, so 100% line+region is achievable without growing `coverage-allowlist.txt`.

## 7. Design soundness / forks — GENUINE FORK (already flagged)
DA1 (a Tab IS the existing `ProcessEntry`; `Workspace.tabIds` references entry ids; per-tab name via `ProcessEntry.tabNameOverride`) is forward-compatible with the cmux model (workspace spans repos / same repo backs many workspaces — because `Workspace` has no single rootPath; dir set derived from tabs). Open edges for ②b: two workspaces sharing an entry id (a tab in two workspaces), and a tab with no live entry. These are fine for ②a (additive shape doesn't preclude promoting a `Tab` struct in ②b) and are recorded as fork #2/#3 for the human in the doing doc.

## Net
One real bug caught (#1) and fixed. Everything else CONFIRMED. The doc is internally consistent with the source at branch-point 40eb132.
</content>
