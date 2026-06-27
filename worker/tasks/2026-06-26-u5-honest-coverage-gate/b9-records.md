# U5 B9 — harness / settings / import / recovery / misc drive-to-100% records

Batch B9 = 12 views / **74 estimated** uncovered regions in the unit2-batch-plan; the
RE-MEASURED baseline at `origin/main` (post-Unit-1 split) is **63 uncovered regions**
(two of the listed views — `HarnessAgentRow` and `SessionStatusListView` — were ALREADY
at 0, fully covered by the C11/C10 render suites; the plan's 74 pre-dated those). Every
reachable region is DRIVEN by INVOKING its closure (ViewInspector 0.10.3
`.tap()`/`.callOnAppear()`/`.callOnDisappear()`/`.callOnChange(oldValue:newValue:)`/
`.callOnSubmit()`/`Stepper.increment()`/`Picker.select()` + the `confirmationDialog`
present-then-`.confirmationDialog(idx).actions()` navigation) and ASSERTING the
side-effect; each was mutation-verified RED→GREEN. The only residual is the genuinely-
unreachable carve seed below.

**Measurement basis:** `xcrun llvm-cov export … WorkbenchViews.swift` segments with
`isRegionEntry && hasCount && count==0`, scoped to each decl's line range, AFTER the full
suite ran with `--enable-code-coverage` and the B9 tests in place.
Script: `b9-measure.py` (this dir).

## RECIPE CORRECTION (load-bearing — the brief's confirmationDialog claim was WRONG)

The brief stated "ViewInspector 0.10.3 descends Menu{}/confirmationDialog". **Menu{} is
descended; `confirmationDialog {}` is NOT reachable via `find(button:)` on the root.**
ViewInspector's `ConfirmationDialog.confirmationDialog(parent:index:)` GUARDS on
`isPresentedBinding().wrappedValue` — the dialog content is reachable ONLY when its
`isPresented` binding is TRUE, and only by navigating `inspect().vStack()
.confirmationDialog(idx).actions().find(button:)` (NOT a root `find`). HarnessStatusSheet's
4 confirmationDialog buttons are driven this way (present the `@Published` flag, navigate
the dialog at source-index 0/1).

| view | decl lines | before | driven | carved | after |
|---|---|---|---|---|---|
| RecoverySheet | 889–980 | 5 | **5** | 0 | **0** |
| HarnessStatusSheet | 1193–1399 | 16 | **14** | 2 | **2 (carve)** |
| HarnessAgentRow | 1466–1545 | 0 | — | 0 | **0** (already covered, C11) |
| HarnessActionResultBanner | 1589–1626 | 1 | **1** | 0 | **0** |
| ShortcutHelpSheet | 1701–1769 | 1 | **1** | 0 | **0** |
| SettingsSheet | 1804–1994 | 9 | **9** | 0 | **0** |
| ImportSummaryBanner | 2012–2120 | 8 | **8** | 0 | **0** |
| ReportBugSheet | 2429–2598 | 9 | **8** | 1 | **1 (carve)** |
| SessionStatusListView | 7663–7720 | 0 | — | 0 | **0** (already covered, C10) |
| TranscriptSearchView | 8070–8137 | 8 | **8** | 0 | **0** |
| ReleaseUpdateView | 10434–10445 | 2 | **2** | 0 | **0** |
| RecoveryDrillView | 10473–10517 | 4 | **4** | 0 | **0** |
| **total** | | **63** | **60** | **3** | **3 (carve)** |

> Line numbers below are the CURRENT file lines (the B9 tests add NO source-shifting seam —
> every view is driven through its existing public/internal init or `@Published` model state).

---

## RecoverySheet (L889–980) — 5 → 5 driven, 0 carved

Test: `RecoverySheetInteractionTests` (SU-D `RecoverySurfaceStateSetTests` covers the render arms).

Driven (each asserted + mutation-verified):
- **"Recover All" `Button { recoverAllRecoverableSessions(); dismiss() }`** (L909): an `autoMany`
  fixture (two trusted+autoResume `.needsRecovery` `.shell` entries → `autoRecoverableEntries.count
  == 2`, the `count > 1` gate) renders the button; `find(button:"Recover All").tap()`.
- **"Done" `Button { dismiss() }`** (L917): tapped (pure environment dismiss).
- **`RecoverableEntryRow` onRecover `{ model.recover(entry) }`** (L964): tapped the `play.fill`-iconed
  recover button → asserted `autoRecoverableEntries` shrinks (the entry begins recovery).
- **`RecoverableEntryRow` onJump `{ selectEntryAcrossGroups(entry.id); dismiss() }`** (L961): tapped
  the "Open" icon button → asserted `selectedEntryID` set.
- **`NeedsYouEntryRow` onJump `{ selectEntryAcrossGroups(entry.id); dismiss() }`** (L946): a `both`
  fixture (one untrusted needs-you) renders the needs-you row; tapped its "Open" → `selectedEntryID` set.

After: **0 uncovered** in L889–980.

---

## HarnessStatusSheet (L1193–1399) — 16 → 14 driven, 2 carved

Test: `HarnessStatusSheetInteractionTests` (C11 `HarnessStatusSheetTests` covers the render arms).

Driven (each asserted + mutation-verified):
- **Refresh `Button { refresh() }`** (L1217): tapped (dispatches the refresh Task).
- **"Done" `Button { dismiss() }`** (L1224): tapped; action-result untouched.
- **embedded-banner dismiss `{ model.harnessActionResult = nil }`** (L1234): set a result → tapped the
  banner's xmark → asserted `harnessActionResult == nil`.
- **repair action-row `{ isRepairHarnessDaemonConfirmationPresented = true }`** (L1321): a daemon-down
  fixture renders "Bring Back Online"; tapped → asserted the flag flips.
- **register action-row `{ isRegisterHarnessMCPConfirmationPresented = true }`** (L1389): a
  boss-unreachable fixture renders "Connect Workbench tools"; tapped → asserted the flag flips.
- **repair `confirmationDialog` "Bring back online" `Button` + its `Task{}`** (L1258/L1259): presented
  the dialog (`isRepairHarnessDaemonConfirmationPresented = true`) → `inspect().vStack()
  .confirmationDialog(0).actions().find(button:"Bring back online").tap()`.
- **repair dialog "Cancel" (`role:.cancel`)** (L1264): same nav, tapped Cancel.
- **register `confirmationDialog` "Connect alpha-boss" `Button`** (L1273): dialog index 1, tapped.
- **register dialog "Cancel"** (L1277): dialog index 1, tapped Cancel.
- **agent-section `hasUnready ? .attention : .healthy`** (L1334): the `.healthy`/FALSE arm via a
  confirmed-ready agent; the `.attention`/TRUE arm via a `.missingConfig` (unready) agent — BOTH arms.
- **boss `mcpPillTone.map { … } ?? .secondary`** (L1374): the `.map` arm via a confirmed-present boss
  injection (non-nil tone); the `?? .secondary` arm via `bossWorkbenchMCPRegistration = nil` (nil tone).

Carved (2 regions — recorded for Unit 3):
| line:col | region | carve kind |
|---|---|---|
| L1196:39 | `@State private var isRefreshing = false` | @State default-value `State(wrappedValue:)` autoclosure — llvm-cov does not count it (the documented @State-default artifact; `isRefreshing` IS used by the `.disabled`/`isBusy` reads). |
| L1281:15 | `.task { model.harnessActionResult = nil; refresh() }` | live-`.task` — ViewInspector 0.10.3 has NO `.task` driver (`callOnAppear`/`callOnDisappear` exist; `.task` does not), so the on-open async closure cannot be invoked in-process. |

After: **2 uncovered** (the 2 carves) in L1193–1399.

---

## HarnessActionResultBanner (L1589–1626) — 1 → 1 driven, 0 carved

Test: `HarnessActionResultBannerInteractionTests` (C11 `HarnessActionResultBannerTests` covers render).

Driven: the close `Button { onDismiss() }` (L1603) — constructed the standalone banner with a captured
`onDismiss` flag, `find(ViewType.Button.self).tap()` → asserted the flag flipped. Mutation: neutralizing
`onDismiss()` → the flag stays false → RED.

After: **0 uncovered** in L1589–1626.

---

## ShortcutHelpSheet (L1701–1769) — 1 → 1 driven, 0 carved

Test: `ShortcutHelpSheetInteractionTests`. Driven: the "Done" `Button { dismiss() }` (L1722) — tapped
(pure environment dismiss; the sheet has no model). After: **0 uncovered**.

---

## SettingsSheet (L1804–1994) — 9 → 9 driven, 0 carved

Test: `SettingsSheetInteractionTests` (C11 `SettingsSheetTests` covers the font-label render arm).

Driven (each asserted + mutation-verified):
- **"Done" `Button { dismiss() }`** (L1814): tapped.
- **font-size `Stepper(value: fontSizeBinding)` setter `{ setTerminalFontSize(CGFloat($0)) }`** (L1846):
  `Stepper.increment()` → asserted `terminalFontSize` 13 → 14.
- **"Reset" `Button { resetTerminalFontSize() }`** (L1859): from 20pt → tapped → asserted reset to the
  macOS default (`defaultTerminalFontSize`, 13).
- **theme `Picker` setter `{ setTerminalThemeOverride($0) }`** (L1888): `Picker.select(value:.dark)` →
  asserted `terminalThemeOverride == .dark`.
- **Chrome `Toggle` setter `{ setShowMenuBarStatusItem($0) }`** (L1909): `.tap()` → asserted flipped.
- **Startup `Toggle` setter `{ setAutoLaunchResumableOnStartup($0) }`** (L1927): `.tap()` → flipped.
- **Updates `Toggle` setter `{ setAutoUpdateEnabled($0) }`** (L1946): `.tap()` → flipped.
- **Advanced "Notification Preferences…" `Button { if let url = URL(string:…) { NSWorkspace.open(url) } }`**
  (L1977 + the inner `if let url` arm L1978): the URL literal is non-nil → tapping runs BOTH regions
  (`NSWorkspace.open` is harmless under test). Tapped.

After: **0 uncovered** in L1804–1994.

---

## ImportSummaryBanner (L2012–2120) — 8 → 8 driven, 0 carved

Test: `ImportSummaryBannerInteractionTests` (C11 `ImportSummaryBannerTests` covers render).

Driven (each asserted + mutation-verified):
- **"Open" `Button { selectEntryAcrossGroups(entryID); lastImportSummary = nil }`** (L2067): with the
  entry present (the Open gate) → tapped → asserted `selectedEntryID` set AND summary cleared.
- **xmark dismiss `Button { lastImportSummary = nil }`** (L2073): tapped → asserted summary cleared.
- **`.onAppear { scheduleDismiss() }`** (L2093): `callOnAppear()` on the banner HStack → enters
  `scheduleDismiss()` (L2105) and creates the dismiss `Task` (L2107). The summary is NOT cleared
  synchronously (the Task body sleeps 7s first).
- **`.onDisappear { dismissTask?.cancel(); dismissTask = nil }`** (L2096): `callOnDisappear()` → ran the
  cancel/clear closure.
- **`scheduleDismiss()` entry (L2105) + `dismissTask = Task { … }` creation INCLUDING its
  `if !Task.isCancelled { … }` body region (L2107/L2109)**: driven via the `.onAppear` above. NOTE: the
  L2109 `if !Task.isCancelled` region was PREDICTED as an async-7s-sleep carve, but the RE-MEASURE shows
  it COVERED — llvm-cov colours the `Task { … }` closure's body REGION at instantiation (the closure
  literal is built when `scheduleDismiss()` runs, even though its continuation hasn't resumed). So the
  region is driven, NOT carved — an honest correction over the initial estimate.

After: **0 uncovered** in L2012–2120.

---

## ReportBugSheet (L2429–2598) — 9 → 8 driven, 1 carved

Test: `ReportBugSheetInteractionTests` (C5 `ReportBugSheet*StateSetTests` cover render).

Driven (each asserted + mutation-verified):
- **"Cancel" `Button { dismiss() }`** (L2444): tapped.
- **"Reveal in Finder" `Button { revealLastBugReport() }`** (L2509): a saved-bundle fixture renders the
  success box; tapped (`NSWorkspace.activateFileViewerSelecting`, no modal).
- **"Copy Path" `Button { copyBugReportPath() }`** (L2515): tapped → asserted the pasteboard holds the
  fixed bundle path (provenance).
- **"File as GitHub Issue" `Button { fileLastBugReportAsGitHubIssue() }`** (L2522): tapped → asserted
  `bugReportIssueIsFiling` flips synchronously (the `gh` work is detached).
- **"Open Issue" `Button { openLastBugReportIssue() }`**: with an issue URL set → tapped
  (`NSWorkspace.open`, no modal).
- **filing-in-progress `if model.bugReportIssueIsFiling { ProgressView() }` arm** (L2530/L2533): rendered
  the success box with `bugReportIssueIsFiling = true` → `find(ViewType.ProgressView.self)` succeeds;
  the idle (false) negative control has NO ProgressView (mutation-verified the gate).
- **"Open Reports Folder" `Button { revealBugReportsFolder() }`** (L2567): tapped → asserted no error
  (the hermetic temp folder is created + opened).

Carved (1 region — recorded for Unit 3):
| line:col | region | carve kind |
|---|---|---|
| L2579:28 | "Create Report" `Button { model.submitBugReport() }` | live-AppKit — `submitBugReport()` synchronously calls `captureKeyWindowPNG()`, which force-touches `NSApp.keyWindow`. `NSApp` is the live `NSApplication!` IUO and is nil in the `xctest` process (no running app), so tapping the button TRAPS (`Fatal error: Unexpectedly found nil` at `WorkbenchViewModel.swift:5107`). No inject seam (the same class as HeaderView's `NSOpenPanel().runModal()` carve). |

After: **1 uncovered** (the carve) in L2429–2598.

---

## TranscriptSearchView (L8070–8137) — 8 → 8 driven, 0 carved

Test: `TranscriptSearchViewInteractionTests` (C10 `TranscriptSearchViewStateSetTests` covers render).

Driven (each asserted + mutation-verified):
- **`.onChange(of: query) { transcriptSearchQueryDidChange() }`** (L8082): this is the iOS-17
  zero-param `onChange(of:_:)` form (`_ValueActionModifier2<String>`), driven by
  `callOnChange(oldValue:newValue:)` over the `String` query.
- **`.onChange(of: focusToken) { _, _ in searchFocused = true }`** (L8085):
  `callOnChange(oldValue: 0, newValue: 1)` over the `Int` token.
- **`.onSubmit { searchTranscripts() }`** (L8088): `callOnSubmit()`.
- **"Search" `Button { searchOrFocus() }`** (L8091) → **`searchOrFocus()` search arm** (L8133): a
  non-empty query → the guard PASSES → `searchTranscripts()` runs.
- **`searchOrFocus()` guard else (focus + return)** (L8129/L8130): a whitespace-only query trims empty
  → the guard FAILS → the `searchFocused = true; return` arm runs (no search).
- **result-row `groupName(for:).map { "\($0) / \(entryName)" } ?? entryName`** (L8103): the `.map` arm
  via a result whose entry resolves a group → "alpha / deploy-runner"; the `?? match.entryName` NIL
  fallback via a match whose entryId is absent from `state` → the bare "orphan-runner" — BOTH arms.

After: **0 uncovered** in L8070–8137.

---

## ReleaseUpdateView (L10434–10445) — 2 → 2 driven, 0 carved

Test: `ReleaseUpdateViewInteractionTests`. `ReleaseUpdateView` is a thin public wrapper around
`WorkbenchReleaseUpdateControls`; no prior test CONSTRUCTED this exact wrapper. Constructing
`ReleaseUpdateView(model:)` runs its `public init` (L10437) and snapshotting evaluates its
`public var body` (L10441). After: **0 uncovered**.

---

## RecoveryDrillView (L10473–10517) — 4 → 4 driven, 0 carved

Test: `RecoveryDrillViewInteractionTests` (C10 `RecoveryDrillViewStateSetTests` covers render but always
INJECTS `.gmt`/`en_GB`).

Driven (each asserted + mutation-verified):
- **`timeZone = .autoupdatingCurrent` / `locale = .autoupdatingCurrent` prod-default autoclosures**
  (L10478/L10479): constructed the view WITHOUT the `.gmt`/`en_GB` seam → the defaults execute.
- **"Run Drill" `Button { runRecoveryDrill() }`** (L10486): tapped on a recoverable state → asserted
  `recoveryDrillResult` set (nil → non-nil; the producer emitted a drill item).
- **result-row `groupName(forEntryId:).map { "\($0) / \(entryName)" } ?? entryName`** (L10501): the
  `.map` arm via a drill item whose entry resolves a group → "alpha / deploy-runner"; the `?? item.
  entryName` NIL fallback via a drill state with the entry but NO project → the bare "deploy-runner" —
  BOTH arms.

After: **0 uncovered** in L10473–10517.

---

## HarnessAgentRow (L1466–1545) + SessionStatusListView (L7663–7720) — 0 → 0 (already covered)

Both were ALREADY at 0 uncovered regions at the B9 baseline — `HarnessAgentRow` fully covered by the
C11 `HarnessAgentRow*` render + MCP-tone leaf suites, `SessionStatusListView` by the C10
`SessionStatusListViewStateSetTests` (the view's own struct has no interaction closures — its row
Button lives in the descended `SessionStatusRowView` child, outside the named decl, already covered).
No B9 work needed; re-measured to confirm.

---

## P2 mutation sweep (non-vacuity — RED→GREEN, all reverted)

Each mutation was applied to the action-closure REGION under test, compiled under
`-warnings-as-errors -strict-concurrency=complete`, made the targeted effect-assertion RED, and was
reverted (source restored to a 0-diff GREEN baseline).

| # | mutation (in `WorkbenchViews.swift`) | test that went RED |
|---|---|---|
| 1 | HarnessStatusSheet repair-row `isRepairHarnessDaemonConfirmationPresented = true` → `= false` | `testHarness_repairActionRow_tapPresentsConfirmation` |
| 2 | ImportSummaryBanner Open `model.selectEntryAcrossGroups(entryID)` → `_ = entryID` (don't select) | `testBanner_openButton_tapSelectsAndClears` |
| 3 | RecoveryDrillView Run-Drill `model.runRecoveryDrill()` → `_ = model` (don't run) | `testDrill_runDrillButton_tapRunsDrill`, `testDrill_negativeControl_runDrillAssignsResult` |
| 4 | HarnessActionResultBanner close `onDismiss()` → `_ = onDismiss` (don't fire) | `testBanner_dismissButton_firesOnDismiss`, `testBanner_negativeControl_dismissFiresForBothTones` |

> Additional per-view non-vacuity is enforced by the dedicated `*_negativeControl_*` tests (the
> filing-ProgressView gate, the Recover-All `count > 1` gate, the settings toggle setters, the
> ImportSummaryBanner action effects, the TranscriptSearch empty-vs-nonempty arm), each asserting a
> captured-node / `@Published` flip that the corresponding source mutation would break.
>
> **Async-launch closures (honest note):** RecoverySheet's `onRecover { model.recover(entry) }` and the
> HarnessStatusSheet refresh/confirmationDialog action bodies dispatch their work to a detached `Task`
> (the C0 async-launch pattern) — they have NO synchronous observable, so the tap DRIVES the region
> (coverage-confirmed) and asserts "no error surfaces"; the region's load-bearing-ness is established by
> the sibling `onJump`/flag mutations (which ARE synchronous). This matches the existing repo pattern
> (HeaderView "Refresh Status"/"Check for Updates" tap tests).

## Determinism (P3)

The clock-bearing B9 view is `RecoveryDrillView` (the `ranAt` status line); its cross-TZ proof is the
C10 `RecoveryDrillViewStateSetTests.testDrill_crossTimeZone_byteIdenticalAcrossPDTEDTUTC` (unchanged).
The B9 interaction tests add `*_interaction_noLeak` per view (`!contains("/Users/")` / `/var/folders/`).
`HarnessStatusSheet`'s `observedAt` footer is a verbatim string (zone-independent, C11-proven). No B9
interaction test introduces a clock surface.

## Gates + carve budget delta for Unit 3

B9 adds **3** carve regions to the Unit-3 allowlist seed:
- HarnessStatusSheet: 2 (`@State isRefreshing` default-autoclosure L1196; `.task` no-driver L1281)
- ReportBugSheet: 1 (live-AppKit `NSApp` submit L2579 — `submitBugReport` traps on nil `NSApp`)

Lowering any of the 3 by 1 would require either a ViewInspector `.task` driver that 0.10.3 lacks, a
live `NSApp` the xctest process doesn't have, or reading an llvm-uncounted @State-default autoclosure —
i.e. the carve set is minimal. (The initially-estimated ImportSummaryBanner async-Task-body carve was
disproven by RE-MEASURE — llvm colours the Task closure body at instantiation, so it is driven, not
carved.)
