# Slice ②a — Baseline Notes (Unit 0)

Captured at branch `feat/slice2a-storage-schema`, pre-any-source-change.

## Baseline gates (GREEN — see `baseline-gate.txt`)
- `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` → **PASS**, 2708 tests, 1 skipped, 0 failures. Exit 0.
- `Scripts/check-coverage.sh` (full, rebuilds with `--enable-code-coverage`) → **PASS**: 146/148 files at 100% line+region, exactly 2 allowlisted exclusions.

> Gate hygiene note: `Scripts/check-coverage.sh --no-build` only works immediately after a coverage-instrumented build. Running a plain strict `swift test` afterward makes the test binary newer than the profdata, so `--no-build` then errors "profile data may be out of date". For every coverage gate in this slice, run the FULL `Scripts/check-coverage.sh` (it rebuilds with `--enable-code-coverage`), which is authoritative.

## Schema state of truth (the bump's blast radius)
- `WorkspaceState.currentSchemaVersion = 1` (`Sources/OuroWorkbenchCore/WorkspaceModels.swift:640`). Bumps to **2** in Unit 3b.
- `WorkspaceState.init(from:)` **decodes and PRESERVES** the input `schemaVersion` (`WorkspaceModels.swift:727`: `self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)`). It does NOT reset to current. So a test that decodes input JSON with `"schemaVersion": 1` and asserts the loaded value `== 1` STAYS `1` under v2.

### WorkbenchStore load gate (accept-`<=`-current)
- `WorkbenchStore.load` (`WorkbenchStore.swift:128`): `guard state.schemaVersion <= WorkspaceState.currentSchemaVersion else { … reject … }`. Accepts older/equal; rejects ONLY a future (`> current`) file. Bumping current 1→2 keeps v1 loading; only v3+ quarantines. `DegradedRead.swift` derives its `supportedVersion` from the constant — no separate version literal to update.

### Exactly TWO literal-`1` schema tests change to `2` in Unit 3b; a THIRD must STAY `1`
- CHANGE → 2: `DegradedReadTests.swift:72` — `XCTAssertEqual(WorkspaceState.currentSchemaVersion, 2)` (constant pin). Rename enclosing `testCurrentSchemaVersionIsOne()` → `…IsTwo()` (cosmetic, same commit).
- CHANGE → 2: `WorkbenchStoreTests.swift:15` — `XCTAssertEqual(loaded.schemaVersion, 2)` (missing-file load returns a FRESH `WorkspaceState()`, memberwise default = current = 2).
- STAY 1: `PaneLayoutStateTests.swift:73` — `XCTAssertEqual(state.schemaVersion, 1)`. It decodes input JSON `"schemaVersion": 1` (line 58) and asserts the DECODE-PRESERVED value. Flipping it to 2 would BREAK the test (it still loads as 1). Confirmed against source.
- All other schema refs go through `WorkspaceState.currentSchemaVersion` ± offset (`WorkbenchStoreTests` older=current-1, ==current, newer=current+1, zero; `DegradedReadTests` tooNew=current+1) — bump-safe, untouched. Input-only `"schemaVersion": 1` fixtures that never assert the loaded version are also untouched.

## Existing patterns the new code mirrors (verified)
- Lenient collection decode: `container.decodeLenientArray(T.self, forKey:, into: &report, collection:)` (`FailableDecodable.swift:25`; used for `projects`/`processEntries`/`processRuns`/`actionLog`/`decisionLog`/`proseLog` in `WorkspaceState.init(from:)`). New `workspaces` follows this. Drop is attributed into `decodeReport.skippedByCollection[<name>]` — existing test `testLenientDecodeSkipsCorruptElementsKeepsGoodOnes` asserts `["projects"] == 1`.
- `decodeIfPresent` optional pattern: `ProcessEntry.tabNameOverride` mirrors `discoveredSessionId`/`attentionReason` (decode-if-present, default nil; new param last+defaulted in memberwise init so the 210 `ProcessEntry(...)` / 191 `WorkspaceState(...)` call sites are unaffected — Swift inits require labels).
- `CodingKeys` deliberately EXCLUDES `decodeReport` (it describes a decode pass, not durable state). `workspaces` is ADDED to `WorkspaceState.CodingKeys`; `tabNameOverride` is ADDED to `ProcessEntry.CodingKeys`.
- Mutating-migration pattern: `applyAutomaticBossDefaults()` / `pruneProcessRuns()` (`extension WorkspaceState`). New `migrateToWorkspaceStructure()` follows the same shape; idempotent (no run-once gate — DA3).
- `ProcessEntry.isArchived` exists (`WorkspaceModels.swift:221`, decode-if-present default false) — the archived-excluded migration rule (DA6) keys off it.

## App bootstrap anchor (Unit 5)
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`:
  - `:19942` `state = startupRecoveryReconciler.reconcile(bootstrapper.bootstrappedState(from: loaded))`
  - `:19943` `applyCollapsedChromeMigrationIfNeeded()`
  - `:19944` `applyAutomaticBossDefaultsMigrationIfNeeded()`
  - Add `state.migrateToWorkspaceStructure()` right after `:19944` (mutating call on `state`). No run-once gate (idempotent, DA3). Both bootstrap/reconcile do `var next = state` then mutate-and-return — `workspaces` passes through untouched.

## Fixture (`fixtures/v1-malformed-resume-state.json`)
- `schemaVersion: 1`; 1 project; 6 `processEntries` (4 whose `name` begins `"Resume "` + 2 normal); NO `workspaces` key; NO `tabNameOverride` on any entry. Synthetic (no real operator data). Validated by `python3 -m json.tool`. Enum raw values (`terminalAgent`, `claudeCode`, `openAICodex`) confirmed against source. This is the migration/backcompat input for Units 2a/3a/4a.
