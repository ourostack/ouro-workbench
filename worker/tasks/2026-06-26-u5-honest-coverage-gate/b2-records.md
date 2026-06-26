# U5 Unit 2 — B2 (header / boss / autonomy cluster) drive-to-100% records

**Measured on** `WorkbenchViews.swift` @ branch `u5-b2-header-boss-autonomy` (off `origin/main 9a635ef`,
post-B4). Coverage via `swift test --enable-code-coverage` → `xcrun llvm-cov export/show … WorkbenchViews.swift`
(gate metric = code-region segments with `kind==0 && count==0`).

## The corrected recipe (Ari: 100% is the bar — earlier carving was WRONG)

ViewInspector 0.10.3 **descends `Menu {}` content** AND **invokes action-closures**
(`find(button:).tap()`, `callOnAppear()`, `callOnSubmit()`). Verified by a standalone probe: tapping
"Harness Status…" INSIDE HeaderView's More-`Menu` flipped `model.isHarnessStatusPresented`. So the prior
campaign's carving of in-closure button/onChange/onSubmit/onAppear regions was wrong — they are DRIVABLE.
Each driven region: invoke the closure → assert the `@Published`/`state` side-effect → mutation-verify
(mutate the action body → effect-assertion RED → revert → GREEN). The mutation sweep is recorded below.

## File-summary delta (B2 cluster)

| metric | BEFORE (post-B4) | AFTER B2 |
|---|---|---|
| WorkbenchViews.swift region | 66.57% (999 uncov / 2988) | **69.11% (923 uncov / 2988)** |
| WorkbenchViews.swift line | 82.39% | **84.74%** |
| **B2 cluster uncovered regions** | **96** | **20** (all genuine carves) |
| tests | 3448 / 1 skip / 0 fail | **3504 / 1 skip / 0 fail** (+56 B2 tests) |

## Per-view BEFORE → driven (via INVOCATION + effect asserted + mutation RED→GREEN) → carved → AFTER

| view | line | BEFORE uncov | AFTER uncov | driven | carved |
|---|---|---|---|---|---|
| HeaderView | 4042 | 34 | **2** | 32 | 2 |
| BossSelectorView | 4332 | 14 | **3** | 11 | 3 |
| AutonomyStatusCheckRow | 4813 | 11 | **1** | 10 | 1 |
| BossAgentNamePopover | 4482 | 7 | **0** | 7 | 0 |
| BossWatchHeaderToggle | 4289 | 1 | **0** | 1 | 0 |
| OnboardingBossChoice | 4536 | 1 | **0** | 1 | 0 |
| AutonomyStatusButton (K1 partial) | 4572 | 9 | **6** | 3 | 6 |
| AutonomyStatusPopover (K1 partial) | 4671 | 14 | **7** | 7 | 7 |
| ext.AutonomyRemediationKind | 4912 | 5 | **1** | 4 | 1 |
| **B2 total** | | **96** | **20** | **76** | **20** |

### HeaderView (34→2) — `HeaderViewInteractionTests`
DRIVEN via INVOCATION (each tap asserts a `@Published`/`state` mutation):
- update badge: real `.updateAvailable` `ReleaseUpdateSnapshot` → `updateBadgeText` non-nil → the badge
  Button renders; tapped (by its `arrow.down.circle.fill` icon) → `updatePrompt == .installable`.
- Hide/Show Boss Pane → `state.bossPaneCollapsed` flips. Commands → `isCommandPalettePresented`.
  Check In (no boss) → `isOnboardingPresented`.
- More `Menu{}` (descended): Set up a boss → onboarding; Create an Agent → `isProviderConfigPresented` +
  `providerConfigIsNewAgent`; Clone → `isOuroAgentInstallSheetPresented`; Save Workspace As… (no
  terminals) → the no-terminals `errorMessage` (early-return BEFORE the NSSavePanel); Harness Status →
  `isHarnessStatusPresented`; Refresh Status (Task wrapper) runs; Recover All Crashed… ENABLED by a real
  `.respawn` recoverable entry → tapped; Settings/Shortcuts/Report Bug/About/Reset → their `is…Presented`
  flags; Check for Updates (Task wrapper) runs; Boss Watch `Toggle` setter flips `bossWatchIsEnabled`;
  recent-workspaces sub-`Menu`: per-path "open" Button + "Clear Recent Workspaces" → empties the list.
- MUTATION-VERIFY: `model.isCommandPalettePresented = true` → `= model.isCommandPalettePresented` (no-op) →
  `testHeader_commandsButton_presentsPalette` RED → reverted → GREEN.

CARVE (2) — recorded for Unit 3:
- `L4134:24→L4136:18` — the "Open Workspace…" Button action `model.presentOpenWorkspacePanel()`. The method
  enters a BLOCKING `NSOpenPanel().runModal()` with NO early-return seam — tapping deadlocks the test.
  Live AppKit modal. (Contrast "Save Workspace As…", DRIVEN — it `guard`-returns before its panel.)
- `L4193:24→L4195:18` — the "Stop All Running…" Button action `model.stopAllRunningSessions()`. The button
  is `.disabled(model.activeSessions.isEmpty)`; enabling it requires a live `TerminalSessionController` in
  `activeSessions` (a live-PTY seam with no hermetic constructor); ViewInspector refuses a disabled tap.

### BossSelectorView (14→3) — `BossSelectorViewInteractionTests`
DRIVEN: per-choice select Button (`selectBoss(agentName:)` → `state.boss.agentName` changes) + the
unselected-row `Text` arm; Use Other Boss…; Manage Agents… (`selectAgent` → `selectedAgentName`);
Create an Agent (provider form); Clone (install sheet); the `menuLabel(for:)` status-suffix switch ALL
arms (authExpired/unreachable/disabled/missingConfig/invalidConfig/missing) via injected `ouroAgents` +
`agentOutwardVerdicts`. MUTATION-VERIFY: `selectBoss(agentName: agentName)` → `(agentName: "")` →
`testSelector_selectBossRow_changesBoss` RED → reverted → GREEN.

CARVE (3): `L4334:48`/`L4335:41` — the `@State customBossIsPresented = false`/`draftAgentName = ""`
default-value property-wrapper storage initializers (no app seam to flip the default value region).
`L4429:55→L4437:10` — the `.popover(isPresented:)` content closure (`BossAgentNamePopover`); ViewInspector
does NOT descend `.popover{}` (documented) — `BossAgentNamePopover` is DRIVEN STANDALONE (0 residual).

### AutonomyStatusCheckRow (11→1) — `AutonomyStatusCheckRowInteractionTests`
DRIVEN: the `repairButton` action + `apply(_:)` switch for the 5 non-login kinds — `.trustTerminals`
(untrusted agent → trusted), `.enableResume` (non-auto-resume claude → resumed), `.connectTools`
(`.notRegistered` MCP → install), `.recover` (real `.respawn` entry), `.enableWatch` (persisted watch-OFF
→ enabled). Each glyph asserted in the tree. MUTATION-VERIFY: `model.trustUntrustedAutonomyAgentTerminals()`
→ `_ = model` → `testApply_trustTerminals` RED → reverted → GREEN.

CARVE (1): `L4906:9→L4907:39` — `apply(.openAtLogin) { loginItem.setEnabled(true) }`. Gated by
`loginItemActionable = loginItem.status != .appBundleMissing` and a live login button — `LoginItemController`
is non-injectable (allowlist candidate #6).

### BossAgentNamePopover (7→0) — `BossAgentNamePopoverInteractionTests`
DRIVEN STANDALONE (real `@Binding`s over a boxed value): `.onAppear`; Cancel (`isPresented=false`); Use
(valid name → `selectBoss` + dismiss); `.onSubmit(apply)` for BOTH `apply` arms — invalid name → the
`guard canApply else { return }` arm (boss unchanged, stays open); valid name → the success arm; the
invalid-name warning `Text`. MUTATION-VERIFY: `model.selectBoss(agentName: trimmedAgentName)` →
`(agentName: "")` → `testPopover_use_validName…` RED → reverted → GREEN.

### BossWatchHeaderToggle (1→0) — `BossWatchHeaderToggleInteractionTests`
DRIVEN: a `.ready` boss agent → `currentBossIsUsable` → the pill is visible; its Button tapped →
`bossWatchIsEnabled` flips. Negative control: no usable boss → pill hidden (button search throws).
MUTATION-VERIFY: `setBossWatchEnabled(!model.bossWatchIsEnabled)` → `(model.bossWatchIsEnabled)` (no-op) →
`testToggle_pillTap_flipsWatch` RED → reverted → GREEN.

### OnboardingBossChoice (1→0) — `OnboardingBossChoiceLogicTests`
NOT a View (renders no captured node) → DIRECT logic test (D8): `id == name` (the uncovered getter) +
`isUsable`/`statusLabel`/`statusColor` arms.

### AutonomyStatusButton (9→6, K1 PARTIAL split per D9) — `AutonomyStatusButtonInteractionTests`
DRIVEN (non-login, 3): the `pillTint` `.real` arm (boss-set model → `HeaderCalmPresentation` `.real` →
the arm executes); the button action `{ loginItem.refresh(); isPresented.toggle() }` via `.tap()`;
`.onAppear { loginItem.refresh() }` via `callOnAppear()`. (The tap/onAppear actions mutate only internal
`@State`/live login state — no external effect to assert beyond non-throwing execution.)

CARVE (6) — recorded for Unit 3:
- `L4574:42` / `L4575:38` — `@StateObject loginItem = LoginItemController()` (the non-injectable login
  carve) and `@State isPresented = false` default-value storage initializers.
- `L4610` / `L4617` / `L4624` — the `loginItemCheck` `.needsUpdate` / `.notInstalled` / `.appBundleMissing`
  arms. `LoginItemController.status` is `@Published private(set)`, read from `LaunchAgentLoginItem
  .defaultAppURL()` at `init()` with NO injection seam → only the ONE case this runner's machine reports
  (`.enabled` here) executes; the other 3 are unreachable in-process. (Candidate #6.)
- `L4656:45→L4664:10` — the `.popover` content closure (`AutonomyStatusPopover`); `.popover` non-descent.

### AutonomyStatusPopover (14→7, K1 PARTIAL split per D9) — `AutonomyStatusPopoverInteractionTests`
Constructed STANDALONE (it is the top-level view here, NOT presented via `.popover`) → ViewInspector
descends its footer buttons. DRIVEN (non-login, 7): the watch footer Button action + BOTH label ternary
arms ("Pause Watch" from watch-ON, "Watch" from watch-OFF → `bossWatchIsEnabled` flips); the "Connect"
MCP Button action; the "Check In" Button action; the `degradedCheckIds` boss-mcp branch (non-actionable
registration + a boss-mcp `.blocker` → the loud octagon). MUTATION-VERIFY: the watch button's
`setBossWatchEnabled(!…)` → `(…)` (no-op) → `testPopover_watchButton_pause` RED → reverted → GREEN.

CARVE (7) — recorded for Unit 3 (all login-item, non-injectable):
- `L4714:50→L4716:10` — `if loginItem.status == .appBundleMissing { ids.insert("open-at-login") }`.
- `L4790:41→L4796:18`, `L4791:28→L4793:22`, `L4793:30→L4795:22`, `L4794:66`, `L4794:83` — the
  `if !loginItem.isEnabled` "Login"/"Update Login" footer Button, its action, and its label ternary.
- `L4796:18→L4807:14` — the login-gated ViewBuilder continuation block (the `if !loginItem.isEnabled`
  `buildOptional` whose presence/absence is decided by the live, non-injectable login state).

### ext.AutonomyRemediationKind (5→1) — driven via `AutonomyStatusCheckRowInteractionTests`
DRIVEN: the `systemImage` arms for `.trustTerminals` (`checkmark.shield`), `.enableResume`
(`arrow.clockwise`), `.connectTools` (`point.3.connected.trianglepath.dotted`), `.enableWatch` (`eye`),
`.recover` (`arrow.uturn.backward`) — each rendered + asserted as the kind's repair-button glyph.
CARVE (1): `L4921:9→L4921:42` — `.openAtLogin: return "power"`; only rendered for an open-at-login repair
button, which needs `loginItemActionable` (login non-injectable). Candidate #6.

## Carve summary (20 regions → Unit-3 allowlist candidates, all per-arm split per D9)

| kind | regions | views |
|---|---|---|
| login-item non-injectable (`LoginItemController` `@StateObject`/status/isEnabled) | 13 | AutonomyStatusButton (4), AutonomyStatusPopover (7), AutonomyStatusCheckRow (1), ext (1) |
| `.popover` content non-descent (content covered STANDALONE elsewhere) | 2 | BossSelectorView (1), AutonomyStatusButton (1) |
| `@State`/`@StateObject` default-value storage initializers | 3 | BossSelectorView (2), AutonomyStatusButton (1) |
| live AppKit blocking modal (`NSOpenPanel`) | 1 | HeaderView (1) |
| live-PTY-gated disabled button (`activeSessions`) | 1 | HeaderView (1) |

All 20 are genuinely-unreachable through any real seam (verified via `--show-regions` line:col above);
NONE is an un-driven ordinary arm. The 5 K1-partial arms were SPLIT per-arm (D9): the non-login arms of
AutonomyStatusButton/Popover/CheckRow were DRIVEN; only the genuinely-untestable login/PTY/modal arms carve.

## Gate pass lines (actual)

- Strict build `-warnings-as-errors -strict-concurrency=complete`: `Build complete!` (0 warn / 0 err).
- Full `swift test`: `Executed 3504 tests, with 1 test skipped and 0 failures`.
- `swift run OuroWorkbench --uisurfacetest`: EXIT=0.
- `scripts/check-coverage.sh`: PASS — Core/ShellAdapter `149/151 files at 100% line+region`, allowlist=2,
  COVERAGE_DIRS UNCHANGED (the views file is gated in Unit 3, not here).
- `WorkbenchAppSourceRetargetTests` (`assertEveryLibFileIsOrdered`): 3 tests passed.
- No `/Users/` path leak in any new fixture; `SerpentGuide.ouro/` / `default.profraw` / `*.actual.txt`
  / coverage-JSON never staged.

## New test files (one commit per view)

- `HeaderViewInteractionTests.swift`
- `BossSelectorViewInteractionTests.swift`
- `AutonomyStatusCheckRowInteractionTests.swift`
- `BossAgentNamePopoverInteractionTests.swift`
- `BossWatchHeaderToggleInteractionTests.swift`
- `OnboardingBossChoiceLogicTests.swift`
- `AutonomyStatusButtonInteractionTests.swift`
- `AutonomyStatusPopoverInteractionTests.swift`
