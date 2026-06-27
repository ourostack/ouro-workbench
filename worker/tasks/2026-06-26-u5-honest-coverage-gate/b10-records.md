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

## Per-helper records

### WorkspaceFolderDropDelegate (1770–1796) — 12 → MOVED to WorkbenchViewModel.swift, 0 carved
BEFORE: 12 uncovered (`1773:47, 1777:46, 1779:39/55, 1780:35, 1781:56, 1782:36/46, 1787:44/54,
1789:22, 1793:10`). A behavioral `DropDelegate` over `DropInfo`/`NSItemProvider`/`FileManager`/
async `Task` — near-undrivable in-process (no `DropInfo` fixture seam), and it is NOT a view.
DISPOSITION: **MOVED** byte-identically into the ungated `WorkbenchViewModel.swift` (the file that
already holds the terminal/AppKit machinery). PURE-MOVE PROOF: `diff` of the 27-line struct decl
extracted from `git show HEAD:WorkbenchViews.swift` vs the new location → IDENTICAL (0 lines diff);
strict build `-warnings-as-errors -strict-concurrency=complete` clean; `WorkbenchAppSourceRetargetTests`
(appSource union + ordering guards) GREEN; single use site `.onDrop(... delegate:
WorkspaceFolderDropDelegate(model: model))` in WorkbenchViews.swift resolves unchanged (same module).
No `orderedLibFiles` change needed: both `WorkbenchViews.swift` and `WorkbenchViewModel.swift` are
already listed in declaration order, no test slices across this struct, and `assertEveryLibFileIsOrdered`
stays green (no new file). The gated file loses 12 regions WITHOUT a test — the honest disposition.
COMMIT: `c0f6061`.

### WorkbenchGroupColor.swiftUIColor (10647→10625) — 10 → 10 driven, 0 carved
BEFORE: 10 uncovered (the 8 switch arms `.gray/.blue/.green/.orange/.red/.purple/.pink/.teal` +
property/ext entry). DRIVEN: `testWorkbenchGroupColor_swiftUIColor_everyArm` asserts every
`allCases` arm maps to its named SwiftUI color, with a `Set(allCases)==Set(expected.keys)` guard so
a new case can't slip past un-asserted. MUTATION: `.teal: return .teal` → `.gray` → assertion RED
(`Optional(gray) != Optional(teal)`) → revert → GREEN. CARVED: none. COMMIT: `f687bca`.

### AutonomyReadinessState (.tint/.displayName) (4954→) — 7 → 7 driven, 0 carved
BEFORE: 7 uncovered (3 `.tint` color arms + 3 `.displayName` string arms + entry; the `.attention`
displayName is the SHORT "watch" not "attention"). DRIVEN:
`testAutonomyReadinessState_tintAndDisplayName_everyArm` asserts each of `.ready/.attention/.blocked`
for both props (green/orange/red ; "ready"/"watch"/"blocked"). MUTATION: `.attention` displayName
`"watch"` → `"MUTwatch"` → RED → revert → GREEN. CARVED: none. (test in `bc2059c`, promotions `6e9b3b0`)

### DetailPaneID <-> PaneLayoutState.Focus (152–166) — 6 → 6 driven, 0 carved
BEFORE: 6 uncovered (`init(_:)` 2 arms + `.persisted` 2 arms + entries). DRIVEN:
`testDetailPaneID_persistenceBridge_everyArm` asserts both init arms, both persisted arms, and a
round-trip identity. MUTATION: `init` `.secondary: self = .secondary` → `self = .primary` → RED →
revert → GREEN. CARVED: none.

### DetailSplitAxis <-> PaneLayoutState.Axis (136–150) — 5 → 5 driven, 0 carved
BEFORE: 5 uncovered (`init(_:)` 2 arms + `.persisted` 2 arms + entry). DRIVEN:
`testDetailSplitAxis_persistenceBridge_everyArm` — both init/persisted arms + round-trip identity.
MUTATION: `.persisted` `.horizontal: return .horizontal` → `.vertical` → RED → revert → GREEN.
CARVED: none.

### BossWorkbenchMCPRegistrationStatus.harnessTint (1673→) — 5 → 5 driven, 0 carved
BEFORE: 5 uncovered (`.registered` green, `.needsUpdate` orange, compound `.red` arm folding 5
statuses + entry). DRIVEN: `testBossWorkbenchMCPRegistrationStatus_harnessTint_everyArm` asserts
green/orange and loops every red-folded status → `.red`. MUTATION: the compound `.red` arm's
`return .red` → `return .green` → RED (the 5 red statuses now mis-map) → revert → GREEN. CARVED: none.

### WorkbenchImportApplyResult (10588→) — 4 → 4 driven, 0 carved
BEFORE: 4 uncovered: `persisted: Bool = true` default-value region (`10608`), `headline` `(0,_)`
"Nothing imported" arm (`10616`), `detail` `alreadyPresentCount > 0` branch (`10637`), `detail`
`parts.isEmpty ? nil` ternary (`10643`). DRIVEN:
`testWorkbenchImportApplyResult_headlineDetailAndPersistedDefault` exercises all 4 headline arms,
the nil-detail empty case, the rich detail (group/skip/already-present/duplicate-cleanup), and a
construction OMITTING `persisted` to color the default region. MUTATIONS (3, all RED→revert→GREEN):
headline `(0,_)` "Nothing imported" → "MUT nothing"; detail already-present text → "MUTGONE";
`persisted` default `true` → `false`. CARVED: none.

### WorkbenchToolsInjectionRecorder (record/snapshot) (1655→) — 2 → 2 driven, 0 carved
BEFORE: 2 uncovered (`record` store body `1659`, `snapshot` return `1666`). DRIVEN:
`testWorkbenchToolsInjectionRecorder_recordAndSnapshot` records two agents, asserts snapshot
read-back, then asserts last-write-per-agent-wins (re-record overwrites, count stays 2). MUTATION:
`record`'s `outcomes[agentName] = outcome` → `outcomes[agentName] ?? outcome` (breaks last-write-wins)
→ RED → revert → GREEN. CARVED: none.

### Optional<BossWorkbenchMCPRegistrationStatus>.harnessTint (1689→) — 2 → 2 driven, 0 carved
BEFORE: 2 uncovered (the `??` both arms `1692/1693`). DRIVEN:
`testOptionalBossMCPStatus_harnessTint_bothArms` — non-nil delegates to wrapped tint (`.green`),
`nil` reads `.secondary`. MUTATION: `self?.harnessTint ?? .secondary` → `?? .green` → RED (nil case
now wrong) → revert → GREEN. CARVED: none.

### HarnessHealthState (.tint/.displayName) (1627→) — 1 → 1 driven, 0 carved
BEFORE: 1 uncovered (the `.attention` arm `1643`). DRIVEN:
`testHarnessHealthState_tintAndDisplayName_everyArm` asserts all 3 states for both props. MUTATION:
`.attention` displayName `"attention"` → `"MUTattention"` → RED → revert → GREEN. CARVED: none.

### AutonomyRemediationKind.systemImage (4899→) — 1 → 1 driven, 0 carved
BEFORE: 1 uncovered (the `.enableWatch` arm `4943`). DRIVEN:
`testAutonomyRemediationKind_systemImage_everyArm` asserts all 6 repair-kind SF Symbols. MUTATION:
`.enableWatch: return "eye"` → `"MUTeye"` → RED → revert → GREEN. CARVED: none.

### HeaderCalmPresentation.BossDotColor.swiftUIColor (4978→) — 1 → 1 driven, 0 carved
BEFORE: 1 uncovered (the `.orange` arm `5022`). DRIVEN:
`testHeaderCalmPresentationBossDotColor_swiftUIColor_everyArm` asserts all 4 dot colors
(neutral→secondary, green, orange, red). MUTATION (line-precise — `case .orange: return .orange`
appears in many switches, so mutated the exact BossDotColor `.orange` arm by line): `return .orange`
→ `return .green` → RED → revert → GREEN. CARVED: none.

## Mutation sweep summary (anneal P2 — every behavioral arm controlled)

13 mutations across the 11 direct-tested helpers + the WorkbenchGroupColor commit — **every one
caught (RED) and reverted (GREEN)**. Zero uncaught LIVE guards, zero carves (every K4 helper is pure
logic, fully drivable). Restore-from-INDEX (`git checkout -- <file>`, the views file staged so the
restore preserves the private→internal promotions) was used so each mutation ran against the
promoted source — an early sweep error (`git checkout HEAD`) produced false "inconclusive-rebuild"
green-by-absence verdicts and was corrected.

## Region delta on WorkbenchViews.swift (the gate metric)

Re-measured on a GREEN coverage run (`swift test --enable-code-coverage`, 3655 tests / 1 skip /
0 fail), with the per-decl attribution recomputed against the CURRENT (post-move) decl boundaries
(`/tmp/b10-measure-final.py`, committed copy `b10-measure-final.py`):

| metric | BEFORE (branch base) | AFTER (B10) | delta |
|---|---|---|---|
| WorkbenchViews.swift total regions | 2988 | 2976 | −12 (the moved DropDelegate's regions left the file) |
| WorkbenchViews.swift uncovered regions | 710 | 654 | **−56** |
| WorkbenchViews.swift region coverage | 76.24% | 78.02% | +1.78pp |
| **K4 cluster residual** | **56** | **0** | **−56 (fully closed)** |

**−56 = 44 direct-tested + 12 moved-out.** Every one of the 13 K4 helper decls is now at **0**
uncovered regions (moved-out or direct-tested + asserted + mutation-verified). The 5 regions a
STALE absolute-line measure flagged turned out to be VIEWS (`SettingsSheet` `Button("Done")` action,
`TerminalRowContextMenu` button, `CommandPaletteSheet` `.onKeyPress`/`@State` — the file shifted ~34
lines after the move, so the old K4 line-ranges aliased onto view code); the post-move-boundary
measure confirms **0 K4 residual**. Those 5 are pre-existing B1/B6/B9 view residual, NOT K4, NOT
introduced here.

## Carves
**ZERO carves.** Every K4 helper is pure, fully-drivable logic (or moved out). No region was
allowlisted; the `scripts/coverage-allowlist.txt` is UNCHANGED (only the 2 pre-existing
Core entries: `BossAgentMCPClient.swift`, `SessionActivityReader.swift`). `COVERAGE_DIRS` UNCHANGED.

## Gate pass lines
- strict build `-warnings-as-errors -strict-concurrency=complete`: **Build complete!** (0 warn / 0 err)
- `swift test`: **3655 tests, 1 skipped, 0 failures** (a single run showed the pre-existing
  DaemonLiveness timing flake — passes in isolation AND on clean rerun; not ours, pure-logic B10
  tests have no timing).
- `--uisurfacetest`: **EXIT 0**, every surface `ok`.
- `scripts/check-coverage.sh`: **PASS** — Core/ShellAdapter 149/151 at 100% line+region (2
  documented allowlist exclusions, UNCHANGED); allowlist + COVERAGE_DIRS untouched.
- structural guards (`WorkbenchAppSourceRetargetTests`, incl. `assertEveryLibFileIsOrdered`): **3
  tests, 0 failures** — the move needed NO `orderedLibFiles` retarget (no new file; no cross-decl
  slice straddles the moved struct; both files already listed in declaration order).
- no leaks (B10 tests are pure logic — no paths/processes; the path-leak guard passes).

## Worktree / hygiene confirmation
- Stayed entirely in the isolated worktree (`git rev-parse --show-toplevel` = `.claude/worktrees/...`);
  never touched the shared `/Users/microsoft/code/ouro-workbench` checkout.
- Never staged `SerpentGuide.ouro/`, `default.profraw`, `*.actual.txt`, or coverage-export JSON.


