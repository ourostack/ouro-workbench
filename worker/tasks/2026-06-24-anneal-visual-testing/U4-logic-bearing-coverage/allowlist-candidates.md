# Honest-allowlist candidate dossiers (U4)

For the operator's eventual allowlist decision (the FINAL campaign gate step — NOT U4).
Each carries a VERIFIED untestability justification (P1 discipline: the claim is checked,
not asserted). Dossiers are FILLED IN as each cluster confirms the carve-out at execution;
the four candidates + their verified evidence are seeded here from the planning reads @ `7a65601`.

## 1. `WorkbenchRootView` (`:131`) — window/scene shell — **C0 Q1 spike: ALLOWLIST CONFIRMED**
- **Verified shape:** `@StateObject private var model: WorkbenchViewModel` + `@State columnVisibility: NavigationSplitViewVisibility` + `@Environment(\.scenePhase)` + `handleMenuCommand(_:)` dispatch + dockTile/window wiring. Its `body` is the `NavigationSplitView(columnVisibility:)` (`:282`) + menu key-equivalents.
- **Why untestable in-process (CHECKED @ C0):** its ONLY initializer is `init(diagnostics:)` (`:141`) which constructs the `@StateObject` model INTERNALLY — there is **no model-injection seam**, so an in-process host would build a real VM that scans the real `~/AgentBundles` in init (`refreshOuroAgents()`) → a non-hermetic AN-001 leak the temp-`agentBundlesURL` dual-injection can't reach. Plus the `NavigationSplitView` scene shell + `@Environment(\.scenePhase)`. No data-state seam.
- **Disposition:** **ALLOWLIST (Q1 confirmed).** No clean hostable subtree is reachable deterministically; the body IS the split + menu wiring. (Q1 spike record: `edge-case-spikes.md`.)

## 2. `MachineRuntimeView` (`:10170`) — login-item @StateObject — **C0 Q1 spike: ALLOWLIST CONFIRMED**
- **Verified shape (re-confirmed @ C0):** `@StateObject private var loginItem = LoginItemController()` constructed IN-PLACE (`:10172`, no `paths`/init seam); only `MachineRuntimeView(model:)` exists (`:5273`). Its `isEnabled`/`isUpdating`/`lastError` rows are driven by the live login-item service. The `model.supportDiagnostics*` rows ARE model-driven — but they share the SAME `body` as the non-injectable `@StateObject`.
- **Why untestable in-process:** the `@StateObject LoginItemController()` taints the whole view's determinism; no injection seam exists.
- **Disposition:** **ALLOWLIST (login-item arm; Q1 confirmed).** A future `LoginItemController` protocol-injection seam would reclaim it — recorded as a POSSIBLE source-fix, NOT done in U4.

## 3. `SessionDetailView` LIVE arm (`if let session`, `:8499`) — PARTIAL carve — **C0 SU-6: PROVEN**
- **Verified shape:** `if let session = model.activeSession(for: entry) { ... TerminalPane(session: session) ... } else { InactiveTerminalSurface(...) }`.
- **Why partial:** the LIVE arm constructs `TerminalPane` (the live PTY view, `@main`-allowlisted, outside coverage). The INACTIVE `else` arm + the inspector/banner/empty states ARE snapshottable via the real `activeSession == nil` seam (C9).
- **C0 SU-6 proof:** the recipe is PROVEN on this view — a `makeVM` VM with NO launched session renders the inactive arm (`readyToLaunch`/`archived` references committed), and NO `TerminalPane` node appears in either tree (the live arm is provably never constructed). The launch-command path-leak is pinned by a fixed `/tmp/u4` working dir.
- **Disposition:** snapshot the inactive states (C9 — recipe proven C0); **ALLOWLIST the `if let session` live arm only.**

## 4. `DetailSplitContainer` LIVE arms (`:8612`) — PARTIAL carve
- **Verified shape:** each pane is a `SessionDetailView` (whose live arm embeds `TerminalPane`); the container body is `if let split { switch axis ... } else { SessionDetailView(...) }` + the `EmptyPanePicker` empty arm.
- **Disposition:** snapshot the split chrome + `EmptyPanePicker` (inactive/empty arms) via the real seam (C9); ALLOWLIST the live-pane arm.

## 5. `BossDashboardView` `showsAdvanced == true` arm — PARTIAL carve — **C2: CONFIRMED**
- **Verified shape (CHECKED @ C2):** `@State private var showsAdvanced = false` (no init seam) gates `if showsAdvanced { VStack { BossWatchStatusView; OuroAgentManagerView; TranscriptSearchView; MachineRuntimeView(model:); ReleaseUpdateView; RecoveryDrillView; BossWorkbenchMCPSetupView; … ActionLogView } }`.
- **Why untestable in-process (two independent reasons, both verified first-hand @ C2):**
  (a) **Structurally unreachable through the snapshot seam.** `showsAdvanced` is a `@State private` defaulting to `false` with NO init parameter; ViewInspector's synchronous `inspect()` renders the INITIAL `@State`, so the expanded arm is never constructed in a snapshot. There is no seam to flip it (it's toggled only by the in-view Button's `withAnimation` closure, which `inspect()` does not fire).
  (b) **Embeds the non-injectable `MachineRuntimeView`** (allowlist-candidate #2 — its `@StateObject LoginItemController()` taints determinism), so even if the arm were reachable it would inherit #2's untestability.
- **C2 proof:** the REACHABLE collapsed arm is snapshotted fully (5 references); each asserts the **"Show Advanced"** label + the `chevron.down` glyph, which PROVES `showsAdvanced == false` (the expanded label is "Hide Advanced" + `chevron.up`). The `BossDashboardViewStateSetTests.testDashboard_showsAdvancedArm_isUnreachableCollapsedByDefault` records the classification (never fabricating the unreachable state — the C1/AN-006 discipline).
- **Disposition:** snapshot the collapsed arm (C2 — done); **ALLOWLIST the `if showsAdvanced` expanded arm** (structurally unreachable + non-injectable child). The advanced sub-views that ARE independently testable (`BossWatchStatusView` already C0; `OuroAgentManagerView` C0/C8; `TranscriptSearchView`/`RecoveryDrillView`/`BossWorkbenchMCPSetupView` C10/C7; `ActionLogView` C10) are covered STANDALONE in their home clusters — only the EXPANDED-ARM COMPOSITION (which embeds `MachineRuntimeView`) is carved.
