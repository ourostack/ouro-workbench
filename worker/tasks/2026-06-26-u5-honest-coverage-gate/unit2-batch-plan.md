# U5 Unit 2 — batch plan + per-view region targets (RE-MEASURED post-split)

**Measured on:** `WorkbenchViews.swift` @ `origin/main 0c9f803` (post-Unit-1 split), full suite
**3426 tests / 1 skip / 0 fail** with `swift test --enable-code-coverage`, then
`xcrun llvm-cov export … Sources/OuroWorkbenchAppViews/WorkbenchViews.swift`.
Attribution script: `/tmp/uncovered-by-view-postsplit.py` (committed copy:
`uncovered-by-view-postsplit.py` in this dir) over `decls-postsplit.txt`.

## Authoritative file-summary (the gate metric)

| metric | value |
|---|---|
| line | **78.47%** (4,613 uncov of 21,429) |
| **region (the gate)** | **64.99%** (**1,046 uncov** of 2,988) |
| decls with ≥1 uncovered region | 102 of 127 |

> NOTE: the pre-split residual-baseline reported 41.8% region — that number was DILUTED by the
> VM body (10,607–20,716) still in the file. Post-split the views file is 65.0% region; the
> uncovered SEGMENT count (1,046) closely matches the pre-split estimate (~1,019). **1,046 is the
> authoritative target.** The pre-split per-view numbers were approximate; THESE are exact.

## Classification (sums to 1,046)

| bucket | decls | regions | disposition |
|---|---|---|---|
| **K1** dossiered genuinely-untestable carves (#1–#8) | 10 | **330** | → Unit 3 allowlist (carve seed; partial carves have a K2 tail — split per-arm) |
| **K4** non-View behavioral helpers in the gated file | 14 | **72** | → batch B10: direct logic tests OR tiny move to the VM file |
| **K2/K3** closeable views (the real residual close-work) | 78 | **644** | → batches B1–B9, drive + assert + mutation-verify |

## K1 carve seed (10 decls / 330 measured regions) — for Unit 3, NOT closed in Unit 2

| view | regions | dossier | carve kind |
|---|---|---|---|
| WorkbenchRootView | 155 | #1 | FULL shell — scene/menu/`@StateObject` model, no inject seam |
| WorkbenchMenuBarController | 54 | #1 (rides) | FULL — NSMenu/AppKit menu-bar wiring |
| LoginItemController | 23 | #2/#6 | FULL — `@Published private(set)` live login-item status, no init seam |
| AboutSheet | 10 | #8 | FULL — `Bundle.main` build-hash + vendored shell, no data seam |
| MachineRuntimeView | 7 | #2 | PARTIAL — login-item `@StateObject` rows (supportDiagnostics rows COVERED in C10) |
| SessionDetailView | 29 | #3/#7 | PARTIAL — `if let session` live-`TerminalPane` arm (inactive arm COVERED in C9) |
| BossDashboardView | 28 | #5 | PARTIAL — `if showsAdvanced` arm (collapsed arm COVERED in C2) |
| AutonomyStatusPopover | 14 | #6 | PARTIAL — `!loginItem.isEnabled` footer (popover COVERED minus footer in C3) |
| AutonomyStatusButton | 8 | #6 | PARTIAL — boss-set login-tainted `ttfaText` arm (no-boss arm COVERED in C3) |
| DetailSplitContainer | 2 | #4 | PARTIAL — live-pane arm (split chrome COVERED in C9) |

> **CRITICAL for Unit 3 honesty:** the 5 PARTIAL carves' MEASURED residual (29/28/14/8/2 = 81) may
> include a small **K2 tail** — non-carve arms the campaign's chosen fixtures didn't drive. Each
> partial-carve doer (or the Unit-3 doer) MUST `llvm-cov show --show-regions` the decl and split:
> which `^0` arms are the genuinely-untestable live/login/build-hash arm (→ allowlist) vs an
> ordinary un-driven arm (→ DRIVE it, do NOT allowlist). The carve budget is whatever survives that
> split — projected ≤330, likely LESS. **Do NOT seed the allowlist at 330 blind.** The full-shell
> carves (155/54/23/10/7 = 249) are whole-decl untestable (verified dossiers) and are the firm floor.

## K4 behavioral helpers in the gated views file (14 decls / 72 regions) — batch B10

These are NON-View types/enums/extensions that stayed in `WorkbenchViews.swift` after the split.
They are NOT snapshot-able through `ViewSnapshotHost.mapNode` (no Text/Image/a11y node), so the
campaign never touched them. Two dispositions — doer picks per item, records which:

| helper | regions | nature | recommended disposition |
|---|---|---|---|
| WorkspaceFolderDropDelegate | 12 | `DropDelegate` — `validateDrop`/`performDrop` over `DropInfo`/`NSItemProvider`/`FileManager`/async `Task` | **MOVE to VM file** (behavioral, not a view; `DropInfo` is near-undrivable in-process) — flag as the K4 follow-up move |
| WorkbenchGroupColor.swiftUIColor | 10 | pure `switch` → 8 SwiftUI.Color arms | **DIRECT logic test** (`XCTAssertEqual(.gray.swiftUIColor, .gray)` per arm — covers + asserts each arm; Color is nodeless so NOT a snapshot) |
| AutonomyReadinessState | 7 | enum/state logic | DIRECT logic test (assert each case's derived props) |
| DetailSplitState | 6 | `Equatable` struct + helpers | DIRECT logic test (already used by SplitContainer tests — extend) |
| DetailPaneID | 6 | `Hashable` enum + ext | DIRECT logic test |
| AttentionState (extension) | 6 | derived-property extension | DIRECT logic test |
| DetailSplitAxis | 5 | `Hashable` enum + ext | DIRECT logic test |
| BossWorkbenchMCPRegistrationStatus | 5 | status enum | DIRECT logic test |
| AutonomyRemediationKind | 5 | enum | DIRECT logic test |
| WorkbenchImportApplyResult | 4 | `Equatable` result struct (headline/detail producers) | DIRECT logic test (C11 used it as a fixture seam — extend to cover its own arms) |
| WorkbenchToolsInjectionRecorder | 2 | `final class @unchecked Sendable` recorder | DIRECT logic test OR move to VM (behavioral) — doer decides |
| Optional (extension) | 2 | helper ext | DIRECT logic test |
| HarnessHealthState | 1 | enum | DIRECT logic test |
| HeaderCalmPresentation | 1 | presentation resolver (1 residual arm) | DIRECT logic test (mostly covered already) |

> **K4 fork to record:** moving `WorkspaceFolderDropDelegate` (+ optionally `WorkbenchToolsInjectionRecorder`)
> to `WorkbenchViewModel.swift` shrinks the GATED file's residual by 12 (–14) regions WITHOUT a test,
> and is the honest disposition (they are behavioral, not views — same logic as why the VM, terminal
> machinery, and DropDelegate-class code belong in the non-gated file). The rest are pure-logic enums/
> structs/extensions cheaply closeable by direct `XCTAssert` logic tests (NOT snapshots — they render
> no captured node). **Reversible default: MOVE the DropDelegate, DIRECT-TEST the rest.** If a move
> triggers a guard-slice inversion, fallback = direct-test-in-place or allowlist with justification.

## Batch decomposition (B1–B9 = K2/K3 close; B10 = K4) — sequenced high-region-first

Each batch = one coherent reviewable PR-equivalent (this doc is committed, NO PR per brief). Within a
batch, ONE commit per view/sub-unit. Sequence drives highest-leverage first but batches are INDEPENDENT
(disjoint view sets) so they MAY fan out to parallel sub-agents — serialize only the doc commits.

### Per-batch contract (every batch-doer does ALL of this)

1. **Re-measure** its views' uncovered regions FIRST (`llvm-cov show --show-regions` on each decl → the
   `^0` arms + the un-hit `@ViewBuilder`/helper-closure/switch-arm/secondary-body line ranges).
2. For each **reachable** un-hit region: drive its real seam STATE (a fixture the app can actually
   produce — provenance per the ②b law, reuse the proven recipe below), with an **asserting** reference
   (the rendered Text/Image/a11y node), then **MUTATION-VERIFY** (mutate that region's rendered output
   in the fixture → the asserting ref goes RED → revert → GREEN). anneal P2: NO executed-but-unasserted.
3. For each **genuinely-unreachable** region (no seam produces it — confirmed, not assumed): RECORD it as
   a carve candidate for Unit 3 WITH a verified justification. Do NOT contort a test to colour it.
4. **CONFIRM** via coverage re-measure that its views hit ~0 uncovered regions (minus recorded carves).
5. Gates (all green before the batch is done): strict build 0-warn; full `swift test` 0-fail;
   `--uisurfacetest`; `scripts/check-coverage.sh` (Core/ShellAdapter 100%; allowlist + COVERAGE_DIRS
   UNCHANGED until Unit 3); structural guards. NO AI attribution. NEVER stage `SerpentGuide.ouro/` /
   `default.profraw` / `*.actual.txt` / coverage exports.

### Proven recipes (D7 — reuse, never re-derive)

- **Timestamps** → `workbenchTimeText` + cross-TZ proof (`TZ ∈ {PDT,EDT,UTC}` byte-identical). [HeaderView,
  ActionLogView, BossActionReceiptStrip, RunningSessionHeaderControls, RecoveryDrillView, BossWatchStatusView]
- **Agent/VM-backed views** → AN-001 `agentBundlesURL` dual-injection (registrar AND inventory) +
  `makeVM` hermetic. [OuroAgentManagerView, OuroAgentRowView, OuroAgentInstallSheet, ProviderConfigSheet,
  HarnessStatusSheet, AgentDetailView/AgentStatusCard, the boss-dashboard composites]
- **Path-leak** → FIXED relative `/tmp/u4` paths in the fixture; defended `!tree.contains("/Users/")`.
  [AgentInspectorPanel-family, NewTerminalSessionSheet (`workingDirectory`), EditTerminalSessionSheet,
  SessionTitleStrip/InactiveTerminalSurface launch-command + tail.path]
- **Standalone `.popover`/`.contextMenu`** (NOT descended by ViewInspector → instantiate the top-level
  struct standalone) BUT **`Menu{}` IS descended**. [TerminalRowContextMenu, WorkspaceRowContextMenu,
  WorkspaceTabContextMenu, BossAgentNamePopover, AutonomyStatusCheckRow]
- **Live-arm carve** → the real `activeSession == nil` / `showsAdvanced == false` / `!loginItem.isEnabled`
  seam renders the reachable arm; the live arm is allowlisted (K1, Unit 3). [the partial-carve views]
- **ProviderConfigSheet** `NSFullUserName()` → the C6 `init(initialHumanName:)` seam (default = real,
  fixed "Test User" in tests). [already shipped in C6 — extend to the un-hit arms]

---

### B1 — Sidebar + workspace tabs/rows — 12 views / 54 regions
**Recipe:** standalone `.contextMenu`; sidebar rows via `WorkbenchViewModel` state; `GitBranchChip` via the
real `GitSessionStatus.parse(porcelainV2:)` producer (C1); `ElapsedTimePill` via `workbenchTimeText`.

| view | regions | line |
|---|---|---|
| WorkbenchSidebarView | 20 | L3025 |
| TerminalRowContextMenu | 16 | L3615 |
| WorkspaceRowContextMenu | 3 | L3234 |
| WorkspaceTabStrip | 3 | L3309 |
| WorkspaceTabContextMenu | 3 | L3446 |
| SidebarFilterField | 2 | L2946 |
| InlineRenameEditor | 2 | L3271 |
| WorkspaceSidebarRow | 1 | L3169 |
| SidebarAgentRow | 1 | L3488 |
| TerminalAgentRow | 1 | L3717 |
| GitBranchChip | 1 | L3847 |
| ElapsedTimePill | 1 | L3886 |

### B2 — Header + boss-selector + autonomy rows — 6 views / 67 regions
**Recipe:** `HeaderView` via `workbenchTimeText` + the no-boss/boss-set composite (cross-TZ); boss-selector
via real `model` boss state + descended `Menu{}`; `AutonomyStatusCheckRow` standalone. Note `AutonomyStatusButton`/
`AutonomyStatusPopover` are K1 partials (NOT in this batch) — but their NON-carve arms may surface here as
"split the partial" work; coordinate with the K1 split.

| view | regions | line |
|---|---|---|
| HeaderView | 34 | L4042 |
| BossSelectorView | 14 | L4332 |
| AutonomyStatusCheckRow | 11 | L4813 |
| BossAgentNamePopover | 6 | L4482 |
| BossWatchHeaderToggle | 1 | L4289 |
| OnboardingBossChoice | 1 | L4536 |

### B3 — Onboarding flow — 9 views / 79 regions
**Recipe:** onboarding readiness/reconstruct via `onboardingReadiness`/`onboardingReconstructionHandedOff`/
`bossCheckInIsRunning` `@Published` seams (C10); `WorkbenchOnboardingSheet` (46 — top offender) drives every
page/step arm; `MarkdownMessageView` content-pinned.

| view | regions | line |
|---|---|---|
| WorkbenchOnboardingSheet | 46 | L6447 |
| FirstRunBootstrapView | 9 | L6943 |
| OnboardingRepairStepRow | 8 | L7272 |
| OnboardingReadinessView | 5 | L7104 |
| OnboardingBossChoiceView | 4 | L6811 |
| MarkdownMessageView | 3 | L6733 |
| OnboardingBossReconstructView | 2 | L7393 |
| OnboardingFlowHeader | 1 | L6656 |
| FirstRunStepRow | 1 | L7055 |

### B4 — Terminal group/session sheets — 6 views / 113 regions
**Recipe:** sheets via `model.selectedProject`/group/session state; FIXED `/tmp/u4` working dirs
(`workingDirectory` home-path leak — pin it, `!contains("/Users/")`); `TerminalSearchBar`/`TerminalFocusView`
via real search/focus state. Highest-region batch — fan out per-view if needed.

| view | regions | line |
|---|---|---|
| EditTerminalSessionSheet | 22 | L10192 |
| NewTerminalGroupSheet | 20 | L9948 |
| TerminalSearchBar | 20 | L8975 |
| EditTerminalGroupSheet | 17 | L10016 |
| NewTerminalSessionSheet | 17 | L10081 |
| TerminalFocusView | 17 | L9831 |

### B5 — Session detail strip + panels — 11 views / 102 regions
**Recipe:** all through the `activeSession == nil` seam (C9 carve precedent — assert `XCTAssertNil`);
`RunningSessionHeaderControls` (35 — top offender) drive the reachable static composition + recovery/custom
always-true arms (record always-true, don't fake); `workbenchTimeText` for any timestamp; FIXED tail.path.
Watch the carve boundary — the live arms here ride K1 #3/#7.

| view | regions | line |
|---|---|---|
| RunningSessionHeaderControls | 35 | L9644 |
| SessionTitleStrip | 13 | L9067 |
| InactiveTerminalSurface | 11 | L9426 |
| CustomSessionManagementBar | 10 | L9356 |
| SessionInspectorPanel | 9 | L9192 |
| EmptyPanePicker | 9 | L8881 |
| LanePanel | 5 | L8527 |
| TranscriptRehydrationPreview | 5 | L9578 |
| SessionStatusBar | 3 | L9308 |
| SessionTranscriptSheet | 1 | L9260 |
| TranscriptHistoryView | 1 | L9917 |

### B6 — Decision inbox/log + command palette — 4 views / 59 regions
**Recipe:** decision surfaces via `state.recordDecision`/`decisionLog` real producer (C2 InboxDoor precedent);
`CommandPaletteSheet` drives every command-row/filter arm; `DecisionLogRow`/`DecisionInboxSheet` per-state.

| view | regions | line |
|---|---|---|
| DecisionInboxSheet | 21 | L2235 |
| CommandPaletteSheet | 19 | L5032 |
| DecisionLogRow | 14 | L2577 |
| DecisionLogSheet | 5 | L2168 |

### B7 — Agent manager/detail/install + provider — 8 views / 52 regions
**Recipe:** AN-001 dual-injection on every VM fixture; `ProviderConfigSheet` via the C6 `initialHumanName`
seam (extend to un-hit arms); fixed `OuroAgentRecord` + relative paths.

| view | regions | line |
|---|---|---|
| ProviderConfigSheet | 14 | L6148 |
| OuroAgentRowView | 10 | L5982 |
| AgentTitleStrip | 10 | L8189 |
| OuroAgentInstallSheet | 5 | L6322 |
| OuroAgentManagerView | 4 | L5913 |
| AgentHomeEmptyState | 4 | L2817 |
| AgentDetailView | 3 | L8145 |
| AgentStatusCard | 2 | L8376 |

### B8 — Boss dashboard sub-views + watch + receipts — 10 views / 44 regions
**Recipe:** `BossDashboardBuilder().build(...)` + `BossActionReceiptSummary.summarize` real producers (C2/C10);
`ActionLogView`/`BossActionReceiptStrip` via `workbenchTimeText` (cross-TZ); `BossWatchStatusView` fixed epoch.

| view | regions | line |
|---|---|---|
| ActionLogView | 14 | L7782 |
| BossProposalCardList | 7 | L7473 |
| BossConversationView | 6 | L5868 |
| BossActionReceiptStrip | 6 | L7908 |
| BossNeedsMeCodingColumns | 3 | L5443 |
| BossWorkbenchMCPSetupView | 3 | L8103 |
| BossWatchStatusView | 2 | L7985 |
| InboxDoorPill | 1 | L5396 |
| HabitHistoryPanelView | 1 | L5534 |
| MetricStateChip | 1 | L5677 |

### B9 — Harness + settings + import + recovery + misc — 12 views / 74 regions
**Recipe:** `HarnessStatusBuilder` via the live `@Published` inputs (C11 AN-001 hermetic); `ImportSummaryBanner`
via `WorkbenchImportSummaryPresentation` + `WorkbenchImportApplyResult`; `SettingsSheet` font-size label flip;
`RecoveryDrillView` via real `RecoveryDrill().run(state:now:)`; `TranscriptSearchView` direct-`@Published` inject.

| view | regions | line |
|---|---|---|
| HarnessStatusSheet | 16 | L1193 |
| RecoverySheet | 10 | L889 |
| SettingsSheet | 9 | L1804 |
| ReportBugSheet | 9 | L2407 |
| ImportSummaryBanner | 8 | L2012 |
| TranscriptSearchView | 8 | L8035 |
| RecoveryDrillView | 4 | L10438 |
| SessionStatusListView | 4 | L7628 |
| HarnessAgentRow | 2 | L1466 |
| ReleaseUpdateView | 2 | L10399 |
| HarnessActionResultBanner | 1 | L1589 |
| ShortcutHelpSheet | 1 | L1701 |

### B10 — K4 behavioral helpers — 14 decls / 72 regions
**Disposition:** MOVE `WorkspaceFolderDropDelegate` (12) [+ optionally `WorkbenchToolsInjectionRecorder` (2)]
to `WorkbenchViewModel.swift` (non-gated, behavioral — shrinks the gated residual without a test); DIRECT
logic test the rest (pure enums/structs/extensions — `XCTAssert` per arm; NOT snapshots, they render no node).
See the K4 table above. Land this batch BEFORE Unit 3 measures the carve budget (a move changes the residual).

---

## Sequence (high-region-first; B1–B10 each independent — fan-out OK, serialize doc commits)

| seq | batch | views | regions | cumulative closed |
|---|---|---|---|---|
| 1 | B4 Terminal sheets | 6 | 113 | 113 |
| 2 | B5 Session detail | 11 | 102 | 215 |
| 3 | B3 Onboarding | 9 | 79 | 294 |
| 4 | B9 Harness/settings/misc | 12 | 74 | 368 |
| 5 | B2 Header/boss/autonomy | 6 | 67 | 435 |
| 6 | B6 Decision/palette | 4 | 59 | 494 |
| 7 | B1 Sidebar/workspace | 12 | 54 | 548 |
| 8 | B7 Agent/provider | 8 | 52 | 600 |
| 9 | B8 Boss dashboard | 10 | 44 | 644 |
| 10 | B10 K4 helpers | 14 | 72 | 644 + 72 (move/direct) |

**Target after B1–B10:** every non-K1 region driven+asserted+mutation-verified (or moved/direct-tested);
the ONLY remaining views-file residual is K1 (the carve seed, split to its measured minimum in Unit 3).

## Projected Unit-3 allowlist budget (the carve seed — measured MINIMUM, NOT padded)

- **Firm floor (full-shell carves, whole-decl untestable):** 249 regions across 5 decls
  (WorkbenchRootView 155, WorkbenchMenuBarController 54, LoginItemController 23, AboutSheet 10, MachineRuntimeView 7).
- **Partial-carve tail (live/login/build-hash arms only):** ≤81 regions across 5 decls — the EXACT count
  is whatever survives the per-arm `--show-regions` split (non-carve arms get DRIVEN, not allowlisted).
- **Projected total:** ≤330, **likely LESS** once partial carves are split and B10's move lands.
- **Budget is MEASURED AFTER Unit 2** (K1 + any doer-found genuinely-unreachable regions), sized to the
  measured minimum: lowering any carve count by 1 must make `check-coverage.sh` FAIL (proves minimal).
  **K2 must NEVER appear in the allowlist** — it is un-driven, not untestable.

## Genuine forks surfaced (operator chose FULL literal-100%, so defaults adopted)

- **K2-tail-in-partial-carves:** the 5 partial carves' 81 measured regions are NOT all carve — a per-arm
  split is mandatory before Unit 3 (don't blind-seed at 330). Reversible default: split per-arm, drive the
  non-carve arms, carve only the live/login/build-hash arm.
- **K4 DropDelegate move vs carve:** reversible default = MOVE to the VM file (behavioral, not a view).
  Fallback if a guard-slice inverts: direct-test-in-place or carve with justification.
- **No "K2 view that's actually mostly-unreachable" was found** beyond the already-dossiered K1 partials.
  The 78 K2/K3 views are genuinely closeable through real seams (every one renders a captured node).
