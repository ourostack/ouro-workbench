# U5 Unit 2 — batch B10 (K4 non-View behavioral helpers) records

**Branch:** `u5-b10-k4-helpers` off `origin/main` (post B1–B9 landed).
**Scope:** the non-View types/enums/structs/extensions/delegate that stayed in the gated
`Sources/OuroWorkbenchAppViews/WorkbenchViews.swift` after the Unit-1 split. They render NO
captured node through `ViewSnapshotHost.mapNode`, so the snapshot campaign never touched them.
Two dispositions per the batch plan:
- **MOVE** `WorkspaceFolderDropDelegate` (behavioral `DropDelegate` over `DropInfo`/`NSItemProvider`/
  async `Task` — near-undrivable in-process) to the ungated `WorkbenchViewModel.swift` (pure,
  byte-identical same-module relocation; shrinks the gated residual by 12 without a test).
- **DIRECT logic tests** (`XCTAssert` per arm, NOT snapshots) for the pure enums/structs/extensions —
  construct each, exercise every computed-property / init / switch arm, assert, mutation-verify.

**Measurement basis:** `xcrun llvm-cov export … WorkbenchViews.swift`, region-entry segments with
`isRegionEntry && hasCount && count==0`, scoped to each helper's decl line-range, AFTER the full
suite ran with `swift test --enable-code-coverage`. Script: `/tmp/b10-measure.py` (committed copy
`b10-measure.py` in this dir).

## B10 baseline (re-measured @ branch base, full suite — 3644 tests / 1 skip / 0 fail)

WorkbenchViews.swift FILE SUMMARY: **710 uncovered regions** (76.24% region) — post B1–B9.

| helper | L-range | uncov BEFORE | disposition |
|---|---|---|---|
| WorkspaceFolderDropDelegate | 1770–1796 | **12** | MOVE → WorkbenchViewModel.swift |
| WorkbenchGroupColor.swiftUIColor | 10647–10663 | **10** | direct test (8 switch arms + entry + ext) |
| AutonomyReadinessState (.tint/.displayName) | 4989–5011 | **7** | direct test |
| DetailPaneID (init/persist ext) | 152–166 | **6** | direct test |
| DetailSplitAxis (init/persist ext) | 136–150 | **5** | direct test |
| BossWorkbenchMCPRegistrationStatus.harnessTint | 1673–1687 | **5** | direct test |
| WorkbenchImportApplyResult (persisted/headline/detail) | 10588–10645 | **4** | direct test |
| WorkbenchToolsInjectionRecorder (record/snapshot) | 1655–1671 | **2** | direct test |
| Optional<BossMCPRegStatus>.harnessTint | 1689–1695 | **2** | direct test |
| HarnessHealthState (.tint/.displayName) | 1627–1649 | **1** | direct test (`.attention` arm) |
| AutonomyRemediationKind.systemImage | 4934–4946 | **1** | direct test (`.enableWatch` arm) |
| HeaderCalmPresentation.BossDotColor.swiftUIColor | 5013–5028 | **1** | direct test (`.orange` arm) |
| **TOTAL K4 residual** | | **56** | move 12 + direct-test 44 |

> Several plan-listed K4 helpers (`DetailPaneID`/`DetailSplitAxis`/`DetailSplitState` base enums,
> `AttentionState.health*`, `InstalledAgentRowPresentation.DotColor.swiftUIColor`,
> `BossMCPPillPresentation.SemanticColor.swiftUIColor`, `AutonomyReadinessCheckState`,
> `HeaderCalmPresentation` resolver) are ALREADY at 0 uncovered regions — covered by B1–B9's
> view tests. The plan's "72 regions / 14 decls" was the pre-B1-B9 estimate; the exact post-B9
> residual is **56 regions across 12 decls**. Driving these to 0 leaves the K4 cluster fully
> closed (moved-out or direct-tested).

---

## Per-helper records (filled in as each lands)
