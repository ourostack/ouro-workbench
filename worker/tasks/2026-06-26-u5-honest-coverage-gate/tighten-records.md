# Coverage allowlist tightening campaign — per-class drive records

Mission: shrink the `WorkbenchViews.swift` coverage allowlist (`scripts/coverage-allowlist.txt`)
from `1729 379` to its irreducible genuinely-untestable minimum by DRIVING every region a seam,
function-extraction, or direct unit test can reach. Each driven region: INVOKE → ASSERT side-effect
→ MUTATION-VERIFY. Delivered as a sequence of per-class PRs; each bumps VERSION (WorkbenchViews.swift
is release-relevant). CI-measured (the AppViews suite hangs locally on NSFullUserName→Contacts XPC,
so coverage is verified on the CI Coverage job, not locally).

Baseline before this campaign: `WorkbenchViews.swift 1729 379` (main @ b5a1ca3, v0.1.173).

---

## Infra prerequisite — shell-dep freshness (PR #342, v0.1.174)

Not a coverage change: `ouro-native-apple-app-shell` in `Package.resolved` had drifted behind its
live remote `main` (`cf7d9b4` → `9dbc241`), so `check-shell-dependency.sh` (run in all 4 CI jobs)
was RED on `main` — blocking every PR. Bumped the pin; because `Package.resolved` is a
release-affecting path under the release-freshness policy, this also took v0.1.174 (+ CHANGELOG).
Verified the bump changes NO snapshots (HeaderCollapsedInboxBadgeTests pass byte-identical at the
new pin). Kept shell-pure and separate from the coverage PRs per scope hygiene. Merged → published
v0.1.174 → `main` fresh.

---

## Class 1 — WorkbenchRootView.handleMenuCommand (PR #341, v0.1.175)

**Carve before:** the ~30-arm `switch` lived in `private func handleMenuCommand`, behind the
non-executable `@StateObject` `Scene` root and reachable only via `.onReceive` of the
menu-command publisher — ViewInspector 0.10.3 has no driver for that path (residual-baseline.md
K1 #1, flagged "borderline carve" by the independent review).

**Drive:**
- Extracted the switch into the free function `dispatchMenuCommand(_:to:toggleSidebar:)` (K4-helper
  pattern, prod byte-identical — `handleMenuCommand` now forwards to it; the one view-local arm,
  `.toggleSidebar`, is threaded back as a closure param so the free fn stays pure-dispatch).
- Seamed the two model modal calls the `.openWorkspace`/`.saveWorkspace` arms reach
  (`presentOpenWorkspacePanel`/`presentSaveWorkspacePanel`) behind injectable closures
  `chooseWorkspaceOpenURL` / `chooseWorkspaceSaveURL` (default = the real `runModal()` path); only
  the literal `runModal()` line stays behind the default. Prod byte-identical.
- `DispatchMenuCommandTests`: drives all 31 arms + every branch (`.redraw`/`.stopSelected`
  active-entry TRUE+FALSE; `.jumpToAttention` success+empty; `.openWorkspace` value-flow+cancel;
  `.saveWorkspace` route+no-terminals; `.toggleSidebar` closure-fires-not-model). Each asserts the
  model side-effect; mutation spot-check (`.fontIncrease` `by:1`→`by:99`) flips RED then reverted.

**Test-isolation hardening (found via CI, not local):**
- The save/open flows persist the recents list into shared `UserDefaults.standard`
  (`recentWorkspacePaths`), which HeaderView's "Open Recent" submenu reads back. The first cut let
  the save run to a successful write → leaked temp paths → broke `HeaderCollapsedInboxBadgeTests`
  snapshots in the same process (the 2 CI failures). Fixed: save test uses the cancel/no-terminals
  arms (no write) + class-level snapshot/restore of the recents key in setUp/tearDown.
- The setUp/tearDown isolation hit a `-strict-concurrency=complete` error on CI (the `@MainActor`
  class's inherited `nonisolated` setUp/tearDown can't touch `@MainActor`-isolated members). Fixed
  with a file-private non-isolated key constant (drift-guarded by a test) + `nonisolated(unsafe)`
  snapshot box. Now builds clean under the CI flag.

**CI-measured result (Coverage job, run 28296121880):**
- Residual printed by the probe value `1600 330`: **`1650 lines / 342 regions uncovered`**.
- Allowlist set to the exact minimum **`1650 342`** (was `1729 379`).
- **Driven out of the carve: 79 lines / 37 regions.**
- All 4 CI jobs green at `1650 342` (run 28296269169).

**Minimality (count-1) proof:** the probe-then-set protocol IS the count-1 proof — the gate reports
`count - covered`, so the printed residual `1650/342` is exact: `1649` lines or `341` regions each
leave `uncovered > allow` → gate FAILS; `1650/342` passes. Empirically, the `1600/330` probe run
FAILED and printed `1650/342`; the `1650/342` run PASSED.

**Irreducibly kept (this class):** the 1-line `handleMenuCommand` forwarder + the Scene/`.commands{}`
menu wiring + `WindowGroup`/`NavigationSplitView`/`init(diagnostics:)` — all behind the
non-executable `@StateObject` Scene root, genuinely un-constructible/un-inspectable in-process. The
literal `runModal()` syscall lines inside the two workspace-panel default closures (the seam isolates
exactly those).

---

## Class 2 — WorkbenchMenuBarController (PR #344, v0.1.177)

**Carve before:** the whole NSMenu/NSStatusItem AppKit controller (residual-baseline.md K1 #1) —
an `NSObject`, not a SwiftUI view, so ViewInspector has no driver; carved wholesale.

**Drive:**
- Widened `init` private→internal (prod byte-identical — `shared` is the sole production
  construction site and runs the identical body) so a test builds a FRESH, isolated controller, not
  the singleton (no cross-test menu-bar-item contention). Also widened `model`/`menu`/`statusItem`
  for assertion. No logic change.
- `WorkbenchMenuBarControllerTests` drives every reachable region + branch: `attach`; `refreshIcon`
  (no-model early-return / no-active-sessions empty title / active-count title + running tooltip);
  `setVisible`; the `menuNeedsUpdate`→`rebuildMenu` build (guard-no-model FALSE arm; sessions-empty
  vs non-empty; the `count==1 ? "" : "s"` singular/plural ternary both arms; the per-session jump
  rows; `recoverable > 0` TRUE (needs-recovery fixture) + FALSE; the watch on/off ternary both
  arms); and the `@objc` actions (`jumpToSession` guard-pass + guard-fail; `openRecoverySheet`;
  `toggleBossWatch` model + no-model guard; `quickAskBoss` unreachable-boss + running-guard).
  Invoked the `@objc` actions via `perform(Selector)` (Obj-C dispatch reaches private @objc).
- Mutation-verified: `refreshIcon` active-count title (`" \(n)"`→`" X\(n)"`) and the watch ternary
  (arms swapped) each flip RED, then reverted.

**Self-inflicted bug caught en route:** the first test fixture used UUID strings starting `MENB…`,
which are NOT valid hex → `UUID(uuidString:)!` trapped in the static initializer (signal 5). Fixed
to a valid hex prefix. Also: `WorkspaceState.bossWatchEnabled` DEFAULTS to `true` — the watch-off
fixture now sets it explicitly so the on/off menu arms are deterministic.

**CI-measured result (Coverage job, run 28297036990):** residual printed by the probe `1500 270`
was **`1487 lines / 301 regions uncovered`**. Allowlist set to the exact minimum **`1487 301`**
(was `1650 342`). **Driven out: 163 lines / 41 regions.** All 4 CI jobs green at the final value.

**Minimality:** probe-then-set is the count-1 proof — the `1500/270` probe FAILED and printed
`1487/301` (the gate reports `count - covered`), so `1486`/`300` each fail; `1487/301` passes.

**Irreducibly kept (this class):** `quitApp` (`NSApp.terminate(nil)` would kill the test process —
un-invokable); `showWorkbench`'s two `for window in NSApp.windows` loop BODIES (the xctest app has no
windows, so the bodies never run — but its `NSApp.activate`/`unhide` lines ARE covered transitively
by the actions that call it); and the `NSStatusBar.system.statusItem(...)` /
`NSImage(systemSymbolName:)` AppKit construction.

---

## Class 3 — sheet NSOpenPanel value-flows (PR #345, v0.1.178)

**Carve before (b4-carve-records modal-NSOpenPanel):** the four "Choose" directory pickers —
`chooseRootPath` (New/Edit Workspace sheets) and `chooseWorkingDirectory` (New/Edit Terminal
sheets) — configure an `NSOpenPanel` and call `runModal()`, which blocks on a live GUI modal
in-process, so the whole method (panel config + the `if let url { … = url.path }` value-flow) was
carved.

**Drive:** seam each method behind an injectable `var chooseDirectory: (NSOpenPanel) -> URL?`
(default = the real `{ $0.runModal() == .OK ? $0.url : nil }` — prod byte-identical; only tests
inject a stub). The method becomes `if let url = chooseDirectory(panel) { rootPath/workingDirectory
= url.path }`. Tests tap "Choose" (ViewInspector invokes the button action → `chooseRootPath()`),
and the injected stub captures the panel — asserting the panel CONFIGURATION ran as prod
(`canChooseDirectories == true`, `canChooseFiles == false`, single-selection, `directoryURL` seeded
from the current path) and that the value-flow `if let` body executed (stub returns a URL). The
cancel arm (stub returns nil) is covered too. Mutation-verified (`canChooseDirectories` true→false →
the panel-config assertion flips RED, reverted).

**Note on the @State write:** `rootPath = url.path` writes a SwiftUI `@State`; ViewInspector taps
against an internal hosted copy, so the post-tap `@State` is not re-inspectable on the local struct.
The value-flow LINE is covered (the `if let` body runs when the stub returns non-nil), and the
rootPath→field render is independently asserted via the init seam (a sheet seeded with a path renders
it in the field). Only the literal `runModal()` inside each default closure stays carved.

**CI-measured result (Coverage job, run 28297944555):** residual printed by the probe `1450 280`
was **`1406 lines / 287 regions uncovered`**. Allowlist set to the exact minimum **`1406 287`**
(was `1487 301`). **Driven out: 81 lines / 14 regions.**

**Minimality:** probe-then-set — the `1450/280` probe FAILED and printed `1406/287`, so `1405`/`286`
each fail; `1406/287` passes.

**Note — unrelated CI flake observed on the probe run:** `GitSessionStatus.swift:161` (the live
`git status` subprocess success path) showed `1 line / 1 region` uncovered on this run because its
integration test `testReaderReturnsRepoStatusForThisCheckout` does `XCTSkipIf(resolvedGitPath ==
nil)` and git wasn't resolved on that runner. This is a pre-existing environmental flake in a Core
file untouched by this PR (it was 100% on the #344 merge run); re-running the Coverage job clears it.

---

## Class 4 — BossDashboardView showsAdvanced expanded arm (PR #346, v0.1.179)

**Carve before:** `@State showsAdvanced` defaults to `false` with no init seam, so the
`if showsAdvanced` expanded block (BossWatchStatusView, OuroAgentManagerView, TranscriptSearchView,
MachineRuntimeView, ReleaseUpdateView, RecoveryDrillView, BossWorkbenchMCPSetupView, the prompt
block, applied-actions, ActionLogView), the Show/Hide-Advanced label+chevron ternary's expanded
arms, the expanded `idealHeight`/`maxHeight` ternaries, and the `.onChange(of:
transcriptSearchFocusToken)` reveal were unreachable (a post-tap @State toggle is not re-inspectable).

**Drive:** add `init(model:initialShowsAdvanced: Bool = false)` (prod default false → byte-identical
at every call site, incl. the prod WorkbenchRootView) that seeds the @State. Tests:
- collapsed arm (default) — "Show Advanced" + chevron.down, none of the expanded subviews;
- EXPANDED arm (`initialShowsAdvanced: true`) — "Hide Advanced" + chevron.up + the Support-Diagnostics
  (MachineRuntimeView) and Recovery-Drill subview markers (no committed snapshot, since the embedded
  MachineRuntimeView reads machine-local login state — deterministic markers asserted instead);
- expand/collapse gate negative control (Recovery Drill present only when expanded);
- `.onChange(of: transcriptSearchFocusToken)` reveal via `callOnChange`;
- the Show-Advanced toggle button action via `tap`.
Mutation-verified (the Hide/Show label ternary swap → RED, reverted).

**CI-measured result (Coverage job, run 28298452535):** residual printed by the probe `1370 265`
was **`1346 lines / 276 regions uncovered`**. Allowlist set to the exact minimum **`1346 276`**
(was `1406 287`). **Driven out: 60 lines / 11 regions.**

**Irreducibly kept (this class):** the non-injectable MachineRuntimeView login-item leaf (its
SMAppService-class login rows live in MachineRuntimeView's own decl — the next class target).

---

## Class 5 — LoginItemController + MachineRuntimeView login rows (PR #347, v0.1.180)

**Carve before (residual-baseline K1 #2):** carved as the "SMAppService login-item (system svc)" —
but `LaunchAgentLoginItem` is FileManager-based plist I/O, NOT SMAppService. `LoginItemController`
built it in-place (`init()` → `LaunchAgentLoginItem(appURL: .defaultAppURL())`) and `MachineRuntimeView`
held an in-place `@StateObject LoginItemController()`, so the controller logic + login rows read live
machine state and were carved.

**Drive (two prod-byte-identical seams):**
- `LoginItemController.init(loginItem: = LaunchAgentLoginItem(appURL: .defaultAppURL()))` — inject a
  temp-rooted item (real `appURL` file + temp `homeURL`), so `install()`/`uninstall()` write/remove a
  real plist in temp — NO login-item syscall.
- `MachineRuntimeView.init(model:loginItem: = LoginItemController())` — inject a controller in a known
  state via `_loginItem = StateObject(wrappedValue:)`.

`LoginItemControllerTests` (9) drives ALL controller logic hermetically: the 4-case `statusLine` map
(enabled/needsUpdate/notInstalled/appBundleMissing), `setEnabled` install→enabled & uninstall→notInstalled,
the `registerIfNeeded` already-enabled guard-return, the `unregisterIfNeeded` not-installed switch arm,
the `lastError` catch path (residual-baseline :10600, via an appBundleMissing install throw), `refresh`,
`isUpdating`. `MachineRuntimeViewLoginRowsTests` (4) drives the login-row render (the Toggle / statusLine
/ the `if let lastError` Text arm) deterministically + a negative control. Mutation-verified (statusLine
`.notInstalled` → RED, both the controller and the view test go red; reverted). The existing
`MachineRuntimeViewCarveTests` (default live-state controller, strips its machine-local region) is
unaffected.

**CI-measured result (Coverage job, run 28298993999):** the first probe `1310/255` unexpectedly
PASSED (the drive overshot the ~30-region estimate — it covered 24 regions / 84 lines), so a re-probe
at `1250/230` forced the gate to print the exact residual **`1262 lines / 252 regions`**. Allowlist
set to the exact minimum **`1262 252`** (was `1346 276`). **Driven out: 84 lines / 24 regions.**

**Irreducibly kept (this class):** none — the entire LoginItemController + login-row region is driven
(no SMAppService syscall exists; the plist I/O is hermetic).

---

## Class 6 — @State disclosure/inspector/refresh arms (PR #348, v0.1.181)

**Carve before:** four `@State`-no-init-seam arms where a post-tap toggle is not re-inspectable
under ViewInspector — AgentDetailView.showsInspector, SessionDetailView.showsInspector +
showsTranscriptSheet, HarnessStatusSheet.isRefreshing.

**Drive:** add prod-byte-identical `init(... initial<X>: = <current default>)` seams:
- `AgentDetailView` — the `if showsInspector` AgentInspectorPanel arm (asserts chevron.down + the
  inspector's config-path row).
- `SessionDetailView` — the `if showsInspector` SessionInspectorPanel arm + the
  `.sheet(isPresented: $showsTranscriptSheet)` arm. Driven with NO live session, so the live-PTY
  `TerminalPane` arm stays carved. (Asserts chevron flip + the inspector's duplicated pill row;
  the sheet render is path-leak-checked.)
- `HarnessStatusSheet` — the Refresh button `.disabled(isRefreshing)` in-flight arm (asserted via
  ViewInspector `isDisabled()`, since `.disabled` doesn't serialize into the snapshot tree).
Each test seeds the @State + asserts the gated render + a gate negative control. Mutation-verified
(SessionDetailView showsInspector gate → false → RED, reverted).

**CI-measured result (Coverage job, run 28299620615):** residual printed by the probe `1230 238`
was **`1224 lines / 242 regions uncovered`**. Allowlist set to the exact minimum **`1224 242`**
(was `1262 252`). **Driven out: 38 lines / 10 regions.**

**Still carved (later-class candidates):** `taught` (DecisionLogRow has many memberwise params, no
synthesizable init seam without a verbose explicit init), `selectedIndex` (CommandPaletteSheet
keyboard-nav highlight + the irreducible `.onKeyPress` handlers), `customBossIsPresented`
(BossSelectorView popover — the standalone BossAgentNamePopover content is separately drivable).
