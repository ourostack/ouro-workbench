# Honest-allowlist candidate dossiers (U4)

For the operator's eventual allowlist decision (the FINAL campaign gate step — NOT U4).
Each carries a VERIFIED untestability justification (P1 discipline: the claim is checked,
not asserted). Dossiers are FILLED IN as each cluster confirms the carve-out at execution;
the four candidates + their verified evidence are seeded here from the planning reads @ `7a65601`.

## 1. `WorkbenchRootView` (`:131`) — window/scene shell
- **Verified shape:** `@StateObject private var model: WorkbenchViewModel` + `@State columnVisibility: NavigationSplitViewVisibility` + `@Environment(\.scenePhase)` + `handleMenuCommand(_:)` dispatch + dockTile/window wiring. Its `body` is the `NavigationSplitView` + menu key-equivalents.
- **Why untestable in-process:** no data-state seam — the view IS the shell. Q1 (C0) SPIKES whether the synchronous `inspect()` can traverse a `NavigationSplitView`-rooted `@StateObject` view deterministically.
- **Disposition:** ALLOWLIST (spike-gated). If the C0 spike finds a clean hostable subtree, reclaim it; else allowlist with this dossier.

## 2. `MachineRuntimeView` (`:10170`) — login-item @StateObject
- **Verified shape:** `@StateObject private var loginItem = LoginItemController()` constructed IN-PLACE (no `paths`/init seam). Its `isEnabled`/`isUpdating`/`lastError` rows are driven by the live login-item service. The `model.supportDiagnostics*` rows ARE model-driven — but they share the SAME `body` as the non-injectable `@StateObject`.
- **Why untestable in-process:** the `@StateObject LoginItemController()` taints the whole view's determinism; no injection seam exists.
- **Disposition:** ALLOWLIST (login-item arm). A future `LoginItemController` protocol-injection seam would reclaim it — recorded as a POSSIBLE source-fix, NOT done in U4.

## 3. `SessionDetailView` LIVE arm (`if let session`, `:8499`) — PARTIAL carve
- **Verified shape:** `if let session = model.activeSession(for: entry) { ... TerminalPane(session: session) ... } else { InactiveTerminalSurface(...) }`.
- **Why partial:** the LIVE arm constructs `TerminalPane` (the live PTY view, `@main`-allowlisted, outside coverage). The INACTIVE `else` arm + the inspector/banner/empty states ARE snapshottable via the real `activeSession == nil` seam (C9).
- **Disposition:** snapshot the inactive states (C9); ALLOWLIST the `if let session` live arm only.

## 4. `DetailSplitContainer` LIVE arms (`:8612`) — PARTIAL carve
- **Verified shape:** each pane is a `SessionDetailView` (whose live arm embeds `TerminalPane`); the container body is `if let split { switch axis ... } else { SessionDetailView(...) }` + the `EmptyPanePicker` empty arm.
- **Disposition:** snapshot the split chrome + `EmptyPanePicker` (inactive/empty arms) via the real seam (C9); ALLOWLIST the live-pane arm.
