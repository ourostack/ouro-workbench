# U0 Move Manifest — OuroWorkbenchApp.swift → OuroWorkbenchAppViews library

**Captured (Unit 0):** 2026-06-25 · **HEAD:** `8662dd5` · **Source file:** `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` (21,326 lines)

This manifest drives the regression-locked move. It enumerates every top-level
declaration → current source line → destination bucket, PLUS the two catalogs the move
depends on: (1) the cross-marker `sourceSlice` catalog (C1 — declaration-order-sensitive
slices), and (2) the `UISurfaceTest.swift` public-surface list (H2).

> **Scope note for THIS run (Units 0–2 only):** Unit 1 moves exactly ONE leaf view
> (`DashboardRowLabel`, line 4930 — unguarded). Unit 2 retargets `appSource()` + de-dups
> the 43 helper copies. The VM + the four coupled types + the remaining 120 views move in
> Units 3–4 (separate, harder-gated PRs). This manifest is built complete now so Units 3–4
> consume it without re-deriving.

---

## Summary

| Metric | Value |
|---|---|
| Top-level declarations (types) | 148 |
| `: View` structs | 124 (121 distinct app views + 3 generic/nested counted by the grep) |
| Extensions | 16 |
| Nested helper types (cannot split from parent) | 7 |
| Access: `internal` | ~100 |
| Access: `private`/`fileprivate` | ~47 (mostly the views — the dominant widening hazard) |
| Access: `public` (already) | 1 (`TerminalThemeOverride` @ 20615) |

**Destination layout (per the doc):**
```
OuroWorkbenchAppViews/
  Views/         ← the 124 `: View` structs
  WorkbenchViewModel.swift  ← WorkbenchViewModel (10515; nested ExternalDrainOutcome stays with it)
  Terminal/      ← MailboxFetchResult, TerminalThemeOverride, WorkbenchTerminalPalette(+Theme),
                   TerminalPane, TerminalHostView, SingleShotContinuation,
                   TerminalSessionController, CapturingLocalProcessTerminalView   (allowlisted in U4)
  Controllers/   ← WorkbenchMenuBarController (680), LoginItemController (10386)   (allowlisted in U4)
  Support/       ← WorkbenchMenuCommand, DetailPaneID, DetailSplitAxis, DetailSplitState,
                   HarnessActionResult, WorkspaceFolderDropDelegate, WindowChromeConfigurator,
                   WorkbenchToolsInjectionRecorder, OnboardingBossChoice, BossQuickQuestion,
                   WorkbenchImportApplyResult
OuroWorkbenchApp/  (thin exe — stays outside the gated lib)
  OuroWorkbenchApp: App (26), WorkbenchAppDelegate (20), main.swift, UISurfaceTest.swift, WorkbenchUpdateInstaller.swift
```

---

## A. Full type → line → destination inventory

| Line | Type | Kind | Access | `: View`? | Destination |
|---|---|---|---|---|---|
| 20 | WorkbenchAppDelegate | final class | internal | no | **EXE (stays)** |
| 26 | OuroWorkbenchApp | struct (`: App`) | internal | no | **EXE (stays)** |
| 135 | WorkbenchMenuCommand | enum | internal | no | Support/ |
| 153 | DetailPaneID | enum | internal | no | Support/ |
| 162 | DetailSplitAxis | enum | internal | no | Support/ |
| 179 | DetailSplitState | struct | internal | no | Support/ |
| 226 | WorkbenchRootView | struct | internal | yes | Views/ |
| 680 | WorkbenchMenuBarController | final class | internal | no | Controllers/ |
| 902 | WindowChromeConfigurator | struct | private | no | Support/ |
| 941 | RecoverySheet | struct | internal | yes | Views/ |
| 1033 | RecoverySheetSection\<Content\> | struct | private | yes | Views/ |
| 1061 | NeedsYouEntryRow | struct | private | yes | Views/ |
| 1138 | RecoverableEntryRow | struct | private | yes | Views/ |
| 1226 | HarnessActionResult | struct | internal | no | Support/ |
| 1245 | HarnessStatusSheet | struct | internal | yes | Views/ |
| 1452 | HarnessSection\<Content\> | struct | private | yes | Views/ |
| 1493 | HarnessDetailRow | struct | private | yes | Views/ |
| 1515 | HarnessAgentRow | struct | private | yes | Views/ |
| 1595 | HarnessActionRow | struct | private | yes | Views/ |
| 1635 | HarnessActionResultBanner | struct | private | yes | Views/ |
| 1701 | WorkbenchToolsInjectionRecorder | final class | internal | no | Support/ |
| 1747 | ShortcutHelpSheet | struct | internal | yes | Views/ |
| 1816 | WorkspaceFolderDropDelegate | struct | internal | no | Support/ |
| 1850 | SettingsSheet | struct | internal | yes | Views/ |
| 2041 | SettingsSection\<Content\> | struct | private | yes | Views/ |
| 2058 | ImportSummaryBanner | struct | internal | yes | Views/ |
| 2167 | AboutSheet | struct | internal | yes | Views/ (**public — UISurfaceTest**) |
| 2210 | DecisionLogSheet | struct | internal | yes | Views/ |
| 2272 | DecisionInboxSheet | struct | internal | yes | Views/ |
| 2430 | ReportBugSheet | struct | internal | yes | Views/ |
| 2600 | DecisionLogRow | struct | private | yes | Views/ (nested `Mode` enum) |
| 2825 | AgentHomeEmptyState | struct | internal | yes | Views/ |
| 2954 | SidebarFilterField | struct | internal | yes | Views/ |
| 3033 | WorkbenchSidebarView | struct | internal | yes | Views/ (**public — UISurfaceTest**) |
| 3173 | WorkspaceSidebarRow | struct | internal | yes | Views/ |
| 3238 | WorkspaceRowContextMenu | struct | internal | yes | Views/ |
| 3275 | InlineRenameEditor | struct | internal | yes | Views/ |
| 3295 | SidebarWorkspaceEmptyRow | struct | internal | yes | Views/ |
| 3313 | WorkspaceTabStrip | struct | internal | yes | Views/ (**public — UISurfaceTest**) |
| 3446 | WorkspaceTabContextMenu | struct | internal | yes | Views/ |
| 3459 | SidebarActionRow | struct | internal | yes | Views/ |
| 3488 | SidebarAgentRow | struct | internal | yes | Views/ |
| 3598 | SidebarCountBadge | struct | internal | yes | Views/ |
| 3615 | TerminalRowContextMenu | struct | internal | yes | Views/ |
| 3717 | TerminalAgentRow | struct | internal | yes | Views/ |
| 3840 | GitBranchChip | struct | internal | yes | Views/ |
| 3879 | ElapsedTimePill | struct | internal | yes | Views/ (determinism debt: `TimelineView(.periodic(from:.now…))`) |
| 3942 | StatusDot | struct | internal | yes | Views/ |
| 3962 | SessionChip | struct | internal | yes | Views/ |
| 4029 | HeaderView | struct | internal | yes | Views/ |
| 4276 | BossWatchHeaderToggle | struct | internal | yes | Views/ |
| 4319 | BossSelectorView | struct | internal | yes | Views/ (cross-decl slice: `menuLabel(for:)` → next struct) |
| 4469 | BossAgentNamePopover | struct | internal | yes | Views/ |
| 4523 | OnboardingBossChoice | struct | internal | no | Support/ |
| 4559 | AutonomyStatusButton | struct | internal | yes | Views/ (holds `LoginItemController` — E3) |
| 4658 | AutonomyStatusPopover | struct | internal | yes | Views/ (holds `LoginItemController` — E3) |
| 4800 | AutonomyStatusCheckRow | struct | internal | yes | Views/ (holds `LoginItemController` — E3) |
| 4913 | StatusPill | struct | internal | yes | Views/ |
| **4930** | **DashboardRowLabel** | **struct** | **private** | **yes** | **Views/ — ★ UNIT 1 KEYSTONE (unguarded; → public)** |
| 4943 | DashboardStatusLine | struct | private | yes | Views/ |
| 5032 | CommandPaletteSheet | struct | internal | yes | Views/ (nested IndexedRow, SectionedRows) |
| 5207 | BossDashboardView | struct | internal | yes | Views/ |
| 5396 | InboxDoorPill | struct | internal | yes | Views/ |
| 5443 | BossNeedsMeCodingColumns | struct | internal | yes | Views/ |
| 5534 | HabitHistoryPanelView | struct | internal | yes | Views/ |
| 5589 | DashboardMetricsStrip | struct | internal | yes | Views/ (cross-decl slice → MetricStateChip) |
| 5677 | MetricStateChip | struct | internal | yes | Views/ |
| 5720 | WorkbenchVisibilityStrip | struct | internal | yes | Views/ |
| 5777 | MetricChip | struct | internal | yes | Views/ |
| 5817 | MailboxWarningView | struct | internal | yes | Views/ |
| 5839 | BossQuickQuestion | struct | private | no | Support/ |
| 5868 | BossConversationView | struct | internal | yes | Views/ |
| 5913 | OuroAgentManagerView | struct | internal | yes | Views/ |
| 5982 | OuroAgentRowView | struct | internal | yes | Views/ (cross-decl slice → ProviderConfigSheet) |
| 6148 | ProviderConfigSheet | struct | internal | yes | Views/ |
| 6307 | OuroAgentInstallSheet | struct | internal | yes | Views/ |
| 6412 | WorkbenchOnboardingSheet | struct | internal | yes | Views/ (nested `OnboardingPage` fileprivate enum @ 6417) |
| 6621 | OnboardingFlowHeader | struct | private | yes | Views/ |
| 6654 | OnboardingPageContent | struct | private | yes | Views/ |
| 6679 | OnboardingProgressDots | struct | private | yes | Views/ |
| 6698 | MarkdownMessageView | struct | internal | yes | Views/ |
| 6749 | OnboardingStatusRow | struct | private | yes | Views/ |
| 6772 | OnboardingBossChoiceView | struct | private | yes | Views/ |
| 6829 | OnboardingBossChoiceRow | struct | private | yes | Views/ |
| 6902 | FirstRunBootstrapView | struct | private | yes | Views/ |
| 7010 | FirstRunStepRow | struct | private | yes | Views/ |
| 7041 | FirstRunNarrationRow | struct | private | yes | Views/ |
| 7057 | OnboardingReadinessView | struct | private | yes | Views/ |
| 7157 | OnboardingAgentProviderSummary | struct | private | yes | Views/ |
| 7197 | ProviderModelPill | struct | private | yes | Views/ |
| 7219 | OnboardingRepairStepRow | struct | private | yes | Views/ |
| 7340 | OnboardingBossReconstructView | struct | private | yes | Views/ |
| 7420 | BossProposalCardList | struct | internal | yes | Views/ |
| 7438 | BossProposalCard | struct | private | yes | Views/ |
| 7483 | BossProposalItemRow | struct | private | yes | Views/ |
| 7575 | SessionStatusListView | struct | internal | yes | Views/ |
| 7633 | SessionStatusBucketSection | struct | private | yes | Views/ |
| 7662 | SessionStatusRowView | struct | private | yes | Views/ (cross-decl slice → ActionLogView) |
| 7729 | ActionLogView | struct | internal | yes | Views/ |
| 7848 | BossActionReceiptStrip | struct | internal | yes | Views/ |
| 7920 | BossWatchStatusView | struct | internal | yes | Views/ |
| 7963 | TranscriptSearchView | struct | internal | yes | Views/ |
| 8031 | BossWorkbenchMCPSetupView | struct | internal | yes | Views/ |
| 8073 | AgentDetailView | struct | internal | yes | Views/ |
| 8114 | AgentTitleStrip | struct | private | yes | Views/ |
| 8236 | AgentInspectorPanel | struct | private | yes | Views/ |
| 8295 | AgentStatusCard | struct | private | yes | Views/ |
| 8404 | AgentLanesCard | struct | private | yes | Views/ |
| 8443 | LanePanel | struct | private | yes | Views/ |
| 8482 | AgentActionsCard | struct | private | yes | Views/ |
| 8543 | SessionDetailView | struct | internal | yes | Views/ (pane-embedder — touches TerminalPane) |
| 8625 | SessionAttentionBanner | struct | private | yes | Views/ |
| 8678 | DetailSplitContainer | struct | internal | yes | Views/ |
| 8737 | DetailPaneChrome\<Content\> | struct | private | yes | Views/ |
| 8797 | EmptyPanePicker | struct | private | yes | Views/ |
| 8869 | TerminalSearchToggleButton | struct | private | yes | Views/ |
| 8891 | TerminalSearchBar | struct | internal | yes | Views/ |
| 8983 | SessionTitleStrip | struct | private | yes | Views/ |
| 9108 | SessionInspectorPanel | struct | private | yes | Views/ |
| 9176 | SessionTranscriptSheet | struct | private | yes | Views/ |
| 9210 | SessionNotesView | struct | internal | yes | Views/ |
| 9224 | SessionStatusBar | struct | internal | yes | Views/ |
| 9272 | CustomSessionManagementBar | struct | internal | yes | Views/ |
| 9342 | InactiveTerminalSurface | struct | internal | yes | Views/ |
| 9494 | TranscriptRehydrationPreview | struct | internal | yes | Views/ |
| 9560 | RunningSessionHeaderControls | struct | internal | yes | Views/ |
| 9747 | TerminalFocusView | struct | internal | yes | Views/ (E1: holds `TerminalSessionController`, builds `TerminalPane`) |
| 9833 | TranscriptHistoryView | struct | internal | yes | Views/ |
| 9864 | NewTerminalGroupSheet | struct | internal | yes | Views/ (cross-decl slice → EditTerminalGroupSheet) |
| 9932 | EditTerminalGroupSheet | struct | internal | yes | Views/ |
| 9997 | NewTerminalSessionSheet | struct | internal | yes | Views/ |
| 10108 | EditTerminalSessionSheet | struct | internal | yes | Views/ |
| 10216 | SessionNotesEditor | struct | internal | yes | Views/ |
| 10236 | MachineRuntimeView | struct | internal | yes | Views/ |
| 10315 | ReleaseUpdateView | struct | internal | yes | Views/ (**public — UISurfaceTest**) |
| 10323 | WorkbenchReleaseUpdateControls | struct | internal | yes | Views/ (**public — UISurfaceTest**) |
| 10345 | RecoveryDrillView | struct | internal | yes | Views/ |
| 10386 | LoginItemController | final class | internal | no | Controllers/ (E3) |
| 10455 | WorkbenchImportApplyResult | struct | internal | no | Support/ |
| **10515** | **WorkbenchViewModel** | **final class** | **internal** | **no** | **WorkbenchViewModel.swift (→ public; UNIT 3)** |
| 20600 | MailboxFetchResult | struct | private | no | Terminal/ |
| 20615 | TerminalThemeOverride | enum | **public** | no | Terminal/ |
| 20649 | WorkbenchTerminalPalette | enum | internal | no | Terminal/ (nested `Theme`) |
| 20790 | TerminalPane | struct (NSViewRepresentable) | internal | no | Terminal/ (E1; allowlisted U4) |
| 20804 | TerminalHostView | final class | internal | no | Terminal/ |
| 20989 | SingleShotContinuation | final class | private | no | Terminal/ |
| 21007 | TerminalSessionController | final class | internal | no | Terminal/ (E1; **BEFORE** Capturing… — C1) |
| 21239 | CapturingLocalProcessTerminalView | final class | internal | no | Terminal/ (E1) |

### Nested helper types (move WITH parent — never split across files)

| Nested type | Parent | Parent line | Destination |
|---|---|---|---|
| `ReadinessStalenessRefresh` (ViewModifier) | WorkbenchRootView | 226 | Views/ |
| `Mode` (enum) | DecisionLogRow | 2600 | Views/ |
| `IndexedRow`, `SectionedRows` | CommandPaletteSheet | 5032 | Views/ |
| `OnboardingPage` (fileprivate enum @ 6417) | WorkbenchOnboardingSheet | 6412 | Views/ |
| `Theme` (struct) | WorkbenchTerminalPalette | 20649 | Terminal/ |
| `ExternalDrainOutcome` (Sendable) | WorkbenchViewModel | 10515 | WorkbenchViewModel.swift |

### Extensions (16) — placement

| Line | Extends | Access | Category | Placement |
|---|---|---|---|---|
| 187 | DetailSplitAxis | internal | lib-local | Support/ (with DetailSplitAxis) |
| 203 | DetailPaneID | internal | lib-local | Support/ (with DetailPaneID) |
| 219 | Notification.Name | internal | system | **Moves to lib WITH WorkbenchMenuCommand** (doc: "WorkbenchMenuCommand + its Notification.Name"). Names are command notifications the lib's menu wiring posts/observes. (Unit 3 decision — verify no exe-only observer breaks.) |
| 1673 | HarnessHealthState | private | Core/cross-module | Views/ (widen to internal) |
| 1719 | BossWorkbenchMCPRegistrationStatus | private | Core/cross-module | Views/ |
| 1735 | Optional\<…RegistrationStatus\> | private | constrained | Views/ |
| 3567 | InstalledAgentRowPresentation.DotColor | private | Core/cross-module | Views/ |
| 3580 | BossMCPPillPresentation.SemanticColor | private | Core/cross-module | Views/ |
| 3908 | AttentionState | internal | Core/cross-module | Views/ |
| 4899 | AutonomyRemediationKind | private | Core/cross-module | Views/ |
| 4967 | AutonomyReadinessState | private | Core/cross-module | Views/ |
| 4991 | HeaderCalmPresentation.BossDotColor | private | Core/cross-module | Views/ |
| 5008 | AutonomyReadinessCheckState | private | Core/cross-module | Views/ |
| 20631 | WorkbenchGroupColor | internal | Core/cross-module | Terminal/ |
| 21260 | LocalProcessTerminalView | private | SwiftTerm import | Terminal/ |
| 21300 | String | private | system | Terminal/ |

---

## B. Cross-marker `sourceSlice` catalog (C1 — declaration-order-sensitive slices)

> **Why this exists:** `sourceSlice(from:to:)` finds `from`, then `to` ONLY in the range
> AFTER `from`. A slice whose `from`/`to` markers sit in DIFFERENT declarations relies on
> those declarations staying in their current SOURCE ORDER. A naïve alphabetical lib-dir
> glob in `appSource()` would reorder them and turn a behavior-preserving move into a RED
> guard (false fail). Unit 2's concat order MUST be adjacency-preserving (manifest-driven
> declaration order), and these marker pairs MUST be pinned to one file in declaration order.

### B.1 — CROSS-DECLARATION slices (7) — markers in DIFFERENT decls (DANGEROUS)

| # | Test file:line | `from` marker (decl @ line) | `to` marker (decl @ line) | Pin requirement |
|---|---|---|---|---|
| 1 | AgentStatusLineAndMenuReadinessWiringTests.swift:122 | `private func menuLabel(for agentName: String) -> String {` (BossSelectorView @ 4319) | `\nstruct BossAgentNamePopover: View {` (@ 4469) | BossSelectorView BEFORE BossAgentNamePopover, same file/order |
| 2 | BossForwardStatusWiringTests.swift:46 | `private struct SessionStatusRowView: View` (@ 7662) | `struct ActionLogView: View` (@ 7729) | SessionStatusRowView BEFORE ActionLogView |
| 3 | BossMCPPillVerdictWiringTests.swift:353 | `struct OuroAgentRowView: View {` (@ 5982) | `struct ProviderConfigSheet: View {` (@ 6148) | OuroAgentRowView BEFORE ProviderConfigSheet |
| 4 | **CheckpointPromptDeliveryWiringTests.swift:76** | `final class TerminalSessionController` (@ 21007) | `\nfinal class CapturingLocalProcessTerminalView` (@ 21239) | **★ THE C1 ANCHOR.** Both stay in ONE file `Terminal/TerminalSession.swift`, controller BEFORE capturing. 21007 < 21239 confirmed at HEAD. |
| 5 | DaemonChipAvailabilityWiringTests.swift:185 | `struct DashboardMetricsStrip: View {` (@ 5589) | `struct MetricStateChip: View {` (@ 5677) | DashboardMetricsStrip BEFORE MetricStateChip |
| 6 | ReadinessStalenessRefreshWiringTests.swift:109 | `struct WorkbenchRootView: View {` (@ 226) | `\nfinal class WorkbenchMenuBarController` (@ 680) | WorkbenchRootView BEFORE WorkbenchMenuBarController — NOTE these go to DIFFERENT buckets (Views/ vs Controllers/). **Unit 2/3 must verify the concat emits WorkbenchRootView before WorkbenchMenuBarController** (declaration order 226 < 680). |
| 7 | WorkspaceNameDerivationTests.swift:72 | `struct NewTerminalGroupSheet: View` (@ 9864) | `struct EditTerminalGroupSheet: View` (@ 9932) | NewTerminalGroupSheet BEFORE EditTerminalGroupSheet |

### B.2 — "next 4-space func" slices (14) — intra-type METHOD-ORDER-dependent

> These slice `from: <method>` `to: "\n    func "` (next method at 4-space indent). They
> rely on METHOD ORDER inside their type. **HARD CONSTRAINT (H1):** the containing type
> (mostly `WorkbenchViewModel`) MUST move as ONE file, method order byte-preserved, NO
> `extension WorkbenchViewModel {}` extraction across files. Reordering makes "next func"
> capture a DIFFERENT method body → a guard that passes against the wrong region (worse
> than a red).

| # | Test file:line | `from` method (@ line) | Containing type | Currently-next method (@ line) |
|---|---|---|---|---|
| 1 | AgentReadinessOverlayWiringTests.swift:157 | `func refreshOuroAgents()` (12780) | WorkbenchViewModel | resolveBossFromInventoryIfNeeded (12796) |
| 2 | CheckpointPromptDeliveryWiringTests.swift:55 | `private func recordOutput(` (21181) | TerminalSessionController | sizeChanged(...) (21209) |
| 3 | CredentialRotationWiringTests.swift:282 | `func submitProviderConfig(` (18415) | WorkbenchViewModel | beginVaultOnboarding (18553) |
| 4 | CredentialRotationWiringTests.swift:287 | `func beginCredentialRotation(` (18623) | WorkbenchViewModel | completeVaultOnboarding (18698) |
| 5 | CredentialRotationWiringTests.swift:292 | `func completeVaultOnboarding(` (18698) | WorkbenchViewModel | startFirstRunBootstrapIfNeeded (18864) |
| 6 | CredentialRotationWiringTests.swift:297 | `func removeAgent(` (12829) | WorkbenchViewModel | openAgentConfig(_:) (12895) |
| 7 | HarnessReadinessOverlayWiringTests.swift:138 | `func refreshOuroAgents()` (12780) | WorkbenchViewModel | resolveBossFromInventoryIfNeeded (12796) |
| 8 | ReplayDedupWiringTests.swift:161 | `func sweepOrphanedAppliedMarkers() async` (17139) | WorkbenchViewModel | refreshLiveScreenSessions() async (17153) |
| 9 | TerminalLeakReaperWiringTests.swift:65 | `func spawnScreenQuit` (17169) | WorkbenchViewModel | quitPersistentScreenIfNeeded(forEntryId:) (17219) |
| 10 | TerminalLeakReaperWiringTests.swift:191 | `func reapOrphanedScreenSessions` (17241) | WorkbenchViewModel | reconcileStartupAttentionWithLiveSessions (17274) |
| 11 | VaultOnboardingWiringTests.swift:232 | `func beginVaultOnboarding(` (18553) | WorkbenchViewModel | beginCredentialRotation(...) (18623) |
| 12 | VaultOnboardingWiringTests.swift:237 | `func completeVaultOnboarding(` (18698) | WorkbenchViewModel | startFirstRunBootstrapIfNeeded (18864) |
| 13 | WaitingReconcileWiringTests.swift:89 | `func reconcileWaitingSessionsIntoInbox(` (16902) | WorkbenchViewModel | teachBoss(from:autoAdvance:) async (16943) |
| 14 | WorkspaceRootValidationTests.swift:137 | (dynamic — reads a method name from a variable) | WorkbenchViewModel | (resolves at runtime; same intra-VM "next func" family — VM-one-file constraint covers it) |

**Note on `start()→sendInput`:** `CheckpointPromptDeliveryWiringTests.swift:64` slices
`from: "func start() {"` `to: "\n    func sendInput("`. This is INTRA-`TerminalSessionController`
(both `start()` and the controller's `sendInput(` at ~21066 are in the same class) — SAFE as
long as the controller body stays contiguous (it does, in `Terminal/TerminalSession.swift`).
There is a SECOND `func sendInput(` in WorkbenchViewModel (~17473); the slice captures the
controller's because `start()` is inside the controller and `sendInput(` is found AFTER it.
Keeping TerminalSessionController one contiguous block preserves this.

### B.3 — Safe intra-declaration slices

**107** of the 128 `sourceSlice` call sites have both markers inside the SAME top-level
declaration → stable under extraction/reordering of OTHER declarations. No action needed.

### B.4 — Unit 2 concat-order requirement (derived from B.1/B.2)

The shared `appSource()` MUST concatenate lib files in **declaration order** (manifest-driven
ordered list), NOT alphabetical. The cross-decl pairs above whose two markers land in
different files must have those files emitted in declaration order:
- `TerminalSessionController` + `CapturingLocalProcessTerminalView` → keep in ONE file
  (`Terminal/TerminalSession.swift`) in declared order (covers #4, plus `start()→sendInput`).
- `WorkbenchRootView` (Views/) before `WorkbenchMenuBarController` (Controllers/) → the
  ordered file list must place the WorkbenchRootView file before the Controllers file (#6).
- Pairs #1,#2,#3,#5,#7 are all within `Views/` → emit those view files in declaration order.
- All 14 next-4-space-func slices → covered by the VM-one-file + controller-one-file rule.

---

## C. UISurfaceTest.swift public-surface list (H2)

`Sources/OuroWorkbenchApp/UISurfaceTest.swift` is a THIRD in-exe consumer (alongside
`OuroWorkbenchApp: App` and `WorkbenchAppDelegate`). After the move it `import OuroWorkbenchAppViews`
and EVERY view/VM-member it constructs MUST be `public`. The `--uisurfacetest` compile is the
transitive proof the public surface is sufficient — a compile failure = a missed `public`.

### C.1 — Views constructed directly (must be `public` + `public init`)

| View | Construction site | Required `public init` |
|---|---|---|
| `AboutSheet` | `AboutSheet(model: model)` (line 22) | `init(model:)` |
| `WorkbenchReleaseUpdateControls` | `WorkbenchReleaseUpdateControls(model: model, showTitle: false)` (24) | `init(model:showTitle:)` |
| `ReleaseUpdateView` | `ReleaseUpdateView(model: model)` (28) | `init(model:)` |
| `WorkbenchSidebarView` | `WorkbenchSidebarView(model: model)` (179, 337) | `init(model:)` |
| `WorkspaceTabStrip` | `WorkspaceTabStrip(model: model)` (189, 340) | `init(model:)` |

### C.2 — `WorkbenchViewModel` — init + members the surface test touches (all must be `public`)

`public init(paths:)` — `WorkbenchViewModel(paths: WorkbenchPaths(rootURL: root))` (lines 19, 133, 275).

Members read/written by UISurfaceTest (each must be `public`):
`releaseUpdateSnapshot`, `appShellUpdateState`, `releaseUpdateInstallError`,
`releaseUpdateIsChecking`, `toggleWorkspacePin(_:)`, `workspaceSidebarModel`,
`renameWorkspace(_:to:)`, `state`, `removeCustomWorkspaceName(_:)`, `renameTab(_:to:)`,
`beginRename(_:prefill:)`, `inlineRename` (+ its `draft`, `isEditing(_:)`), `commitRename()`,
`cancelRename()`, `activeWorkspaceRow`, `selectedEntryID`, `selectedWorkspaceID`,
`archivedSessionEntries`, `workspaceTabEntries`.

> Reviewers (Unit 3/4) verify the public surface up-front against this list rather than
> discovering gaps at `--uisurfacetest` compile time. **Minimize the public surface:** widen
> to `public` ONLY these members + the App-scene-referenced ones (`WorkbenchRootView`,
> `WorkbenchMenuCommand`); everything else stays `internal` to the lib.

### C.3 — NOT moving (already-imported Core/AppShellUI types UISurfaceTest uses)

`WorkbenchPaths`, `WorkbenchStore`, `WorkspaceState`, `ProcessEntry`, `Workspace`,
`WorkbenchProject`, `BossAgentSelection`, `WorkspaceSidebarPresentation`,
`ReleaseUpdateSnapshot`, `ReleaseUpdateAsset`, `AppShellAboutModel`, `WorkbenchRelease`
— all from `OuroWorkbenchCore` / `OuroAppShellUI` (already imported by UISurfaceTest). No move.

---

## D. THIS-RUN execution order (Units 0–2)

1. **Unit 0** (this file + `baseline-green.txt`): baseline + catalogs. ✔
2. **Unit 1**: create empty `OuroWorkbenchAppViews` lib + `OuroWorkbenchAppViewsTests`; move
   `DashboardRowLabel` (4930, unguarded) → lib (`private`→`public`, add `public init`); write
   `ImportabilityProofTests.swift` (`@testable import` + construct the view). Because
   `DashboardRowLabel` is UNGUARDED, NO `appSource()` retarget is needed in Unit 1 — all
   295 guard markers remain in `OuroWorkbenchApp.swift`.
3. **Unit 2**: retarget `appSource()` to read the UNION of the old file + new lib dir in a
   deterministic adjacency-preserving order; de-dup the 43 `appSource()` + 51 `repoRoot()`
   + 38 `sourceSlice` defs into ONE shared helper. This is a verified NO-OP for guards at
   this point (the only moved code, `DashboardRowLabel`, is unguarded), proving the retarget
   is non-breaking BEFORE Unit 3's first guarded cross-type split.

**STOP after Unit 2.** Units 3–6 (VM move, remaining views, coverage-readiness, final
verification) are separate harder-gated PRs.
