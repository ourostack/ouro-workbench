# U5 residual baseline — measured @ branch base (origin/main 687b6c7, profdata 2026-06-26)

Measured by `swift test --enable-code-coverage` then `xcrun llvm-cov export … Sources/OuroWorkbenchAppViews`.
Scripts: `measure-views-residual.py`, `split-residual-probe.py`, `uncovered-by-view.py` (this dir).
Full suite: **3426 tests, 0 failures** (energy-0 on the snapshot rubric holds).

## Per-file summary (gate metric)

| File | line % | uncov lines | region % | uncov regions |
|---|---|---|---|---|
| WorkbenchViewsAndModel.swift | 58.1% | 13,346 | 41.8% | 3,391 |
| WorkbenchKeyboardAccessibilityContract.swift | 77.0% | 56 | 68.5% | 35 |
| WorkbenchUpdateInstaller.swift | 66.4% | 41 | 27.6% | 21 |
| DashboardRowLabel.swift | 100% | 0 | 100% | 0 |

## Where the WorkbenchViewsAndModel.swift residual lives (uncovered REGION-ENTRY segments)

| Bucket | line range | uncovered region segments | disposition |
|---|---|---|---|
| pre-VM view structs | 167–10606 | **1,019** | the real per-file-100% gap on the VIEWS |
| VM body (contiguous) | 10607–20716 | 2,226 | MOVES OUT to non-gated WorkbenchViewModel.swift |
| post-VM terminal types | 20717–end | 129 | TerminalPane/HostView/SessionController/Capturing — move-with-VM or allowlist |

(Region-entry SEGMENTS != the summary region count exactly, but locate the gaps. The gate uses the
summary `regions.count - covered`; the per-view attribution below uses segments to rank offenders.)

## THE FORK (surfaced to operator): the views' residual is NOT just the 28 branchless views

After the VM moves out, the VIEW structs still carry ~1,019 uncovered region segments spread across
**93 of ~124 top-level decls** — including many ALREADY-snapshotted logic-bearing views. "Has a
mutation-surviving snapshot" (the campaign's energy-0 rubric, P1 = *exercised*) is NOT the same as
"every llvm-cov region executed" (the per-file-100% GATE). The campaign reached energy-0 but NEVER
added the views file to COVERAGE_DIRS, so this gap was never measured until now.

### Top offenders (>= 8 uncovered region segments), bucketed by KIND

**(K1) Dossiered shells/carves — legitimately allowlist (already justified):**
- WorkbenchRootView 155 (scene/menu shell — dossier #1)
- WorkbenchMenuBarController 54 (NSMenu shell — rides #1, AppKit menu wiring)
- LoginItemController 23 + MachineRuntimeView 7 (login @StateObject — dossier #2)
- (SessionDetailView 29 / DetailSplitContainer / live-PTY arms — dossiers #3,#4,#7)
- (BossDashboardView 28 — showsAdvanced arm — dossier #5; AutonomyStatusButton 8 + AutonomyStatusPopover 14 — dossier #6)
- AboutSheet 10 (build-hash — dossier #8)

**(K2) Already-snapshotted logic-bearing views with UN-HIT regions (the surprise — NOT carves, NOT branchless):**
- HeaderView 34, WorkbenchOnboardingSheet 46, RunningSessionHeaderControls 35, DecisionInboxSheet 21,
  WorkbenchSidebarView 20, TerminalSearchBar 20, CommandPaletteSheet 19, HarnessStatusSheet 16,
  TerminalRowContextMenu 16, AutonomyStatusCheckRow 16, DecisionLogRow 14, BossSelectorView 14,
  ProviderConfigSheet 14, ActionLogView 14, SessionTitleStrip 13, InactiveTerminalSurface 11,
  RecoverySheet 10, OuroAgentRowView 10, AgentTitleStrip 10, CustomSessionManagementBar 10,
  SettingsSheet 9, ReportBugSheet 9, FirstRunBootstrapView 9, EmptyPanePicker 9, SessionInspectorPanel 9,
  ImportSummaryBanner 8, StatusPill 8, OnboardingRepairStepRow 8, TranscriptSearchView 8 … (and ~40 more
  with 3-7 each). These have snapshots but the chosen fixtures don't execute every @ViewBuilder arm /
  helper closure / secondary body path.

**(K3) Branchless views (the brief's "~28") + nodeless:** a relatively SMALL slice of the 1,019. Several
already transitively covered (per C11 ledger). The genuinely-uncovered branchless ones are a minority of
the residual.

**(K4) Non-view behavioral helpers in the file** (WorkbenchToolsInjectionRecorder 9,
WorkbenchImportApplyResult 4, WorkspaceFolderDropDelegate 12, AttentionState 6) — some MOVE with the VM
(behavioral), some are tiny extensions to promote/cover.

## Implication

The brief's mental model — "snapshot ~28 branchless + allowlist 8 carves → per-file-100%" — understates
the gate residual by ~30×. To reach an HONEST per-file-100% gate on the views file, U5 must EITHER:
- (A) close the K2 residual too (add the missing fixture states to already-snapshotted views so every
  region executes) — large but in-scope-shaped work, OR
- (B) allowlist the K2 residual — but that VIOLATES the brief's "minimal/honest, do NOT pad" rule (K2 is
  not genuinely-untestable; it's just un-exercised), OR
- (C) re-scope: gate the views file at a HONEST documented threshold that carves ONLY K1 (the verified
  genuinely-untestable shells/live-arms) and treats K2 as the real coverage work — sequenced as its own
  effort, not hand-waved into the allowlist.

This is the genuine fork for the operator. The reversible default this doc adopts: **(A)+(C)** — do the
split (PR#1) and the gate-wiring infra (PR#3 skeleton) now, but the K2 region-closing becomes an explicit,
measured sub-effort (PR#2 expands from "28 branchless" to "close the measured views residual"), and the
allowlist carves ONLY K1. We do NOT pad the budget with K2. If the operator prefers a faster honest gate,
the alternative (gate at a documented partial threshold, K2 tracked as backlog) is recorded.
