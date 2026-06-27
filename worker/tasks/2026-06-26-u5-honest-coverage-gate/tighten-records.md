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
