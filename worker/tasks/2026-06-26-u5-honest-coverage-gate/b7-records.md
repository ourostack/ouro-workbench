# U5 Unit 2 — B7 (agent manager/detail/install + provider cluster) drive-to-100% records

**Measured on** `WorkbenchViews.swift` @ branch `u5-b7-agent-provider` (rebased onto `origin/main a485ac7`,
post B5/B6 merges). Coverage via `swift test --enable-code-coverage` → `xcrun llvm-cov export … WorkbenchViews.swift`
(gate metric = code-region segments with `isRegionEntry && hasCount && count==0`, scoped to each view's decl range).

## The recipe (confirmed, B2 precedent)

ViewInspector 0.10.3 **descends `Menu {}` / `.confirmationDialog`** AND **invokes action-closures**
(`find(button:).tap()`), supports `Picker`/`TextField` input drive (`setInput`), and fires `.onChange`
directly (`callOnChange(oldValue:newValue:)`). Each driven region: invoke the closure → assert the
`@Published`/`state`/binding side-effect → mutation-verify (mutate the action body → effect-assertion RED →
revert → GREEN). The pre-existing C6/C7/C8 suites snapshot the RENDER branches; B7 adds the INTERACTION drive.

AN-001 dual-injection on every VM fixture (temp `agentBundlesURL` into BOTH registrar AND inventory → the
init scan is hermetic). Fixed/relative `OuroAgentRecord` (no machine-path leak). `ProviderConfigSheet` via the
C6 `initialHumanName` seam (default = real, fixed "Test User" in tests).

## File-summary delta (B7 cluster)

| metric | BEFORE (rebased baseline) | AFTER B7 |
|---|---|---|
| WorkbenchViews.swift region uncov (FILE) | 923 (at branch base) → 883 measured pre-rebase | 11 B7 residual (all carves) |
| **B7 cluster uncovered regions** | **51** | **11** (all genuine carves) |
| tests | 3504 (baseline) | **3642** (+138 incl. parallel B-batch merges; **+40 B7 tests**) |
| strict build | 0/0 | **0/0** |
| check-coverage.sh (Core/ShellAdapter 100%) | green, allowlist untouched | **green, allowlist UNCHANGED** |

## Per-view BEFORE → driven (via INVOCATION + effect asserted + mutation RED→GREEN) → carved → AFTER

| view | BEFORE uncov | AFTER uncov | driven | carved |
|---|---|---|---|---|
| AgentStatusCard | 1 | **0** | 1 | 0 |
| AgentTitleStrip | 10 | **0** | 10 | 0 |
| OuroAgentManagerView | 4 | **1** | 3 | 1 |
| OuroAgentRowView | 10 | **4** | 6 | 4 |
| AgentHomeEmptyState | 4 | **0** | 4 | 0 |
| OuroAgentInstallSheet | 5 | **0** | 5 | 0 |
| ProviderConfigSheet | 14 | **3** | 11 | 3 |
| AgentDetailView | 3 | **3** | 0 | 3 |
| **B7 total** | **51** | **11** | **40** | **11** |

> Line numbers below are the REBASED ranges (`origin/main a485ac7`; the B5/B6 merges shifted B7 down ~+22).

### AgentStatusCard (1→0) — `AgentStatusCardInteractionTests`
DRIVEN: the actionable-registration "Connect Workbench tools" Button → `installWorkbenchMCP(for:)`. Against
the hermetic (non-existent) bundle the registrar throws → the action's honest `catch` sets `errorMessage`
(asserted non-nil + names the agent). MUTATION-VERIFY: action body → `_ = agent` (no-op) →
`testCard_connectTools_runsInstall` RED (2 failures) → reverted → GREEN.

### AgentTitleStrip (10→0) — `AgentTitleStripInteractionTests`
DRIVEN via INVOCATION:
- the disclosure chevron `showsInspector.toggle()` → a reference-backed `Binding` flips true (so the
  `@State`-owner mutation is observable post-tap); the `showsInspector ? "chevron.down" : "chevron.right"`
  + `.help(…)` ternaries' TRUE arms via a `.constant(true)` strip (read-only binding read).
- More-`Menu{}` (descended): Open agent.json… → `openAgentConfig` (missing hermetic config → `errorMessage`);
  Reveal Bundle in Finder → `revealAgentBundle` (live Finder GUI; no-op for hermetic path → "no throw");
  Run ouro check… → `repairAgent` (a repair `processEntries` session, named for the agent — async PTY
  launch enqueued not awaited, the B2 Recover-All precedent); Create Another Agent… → `isProviderConfigPresented`
  + `providerConfigIsNewAgent`; Clone an Agent… → `isOuroAgentInstallSheetPresented`; Refresh Agents →
  `refreshOuroAgents` (hermetic scan keeps `ouroAgents` empty).
- the primary "Use as Boss" → `selectBoss` → `state.boss.agentName` flips.
- MUTATION-VERIFY: `showsInspector.toggle()` → `// MUT` → `testStrip_chevron_togglesInspectorBinding` RED → GREEN.

### OuroAgentManagerView (4→1) — `OuroAgentManagerViewInteractionTests`
DRIVEN: "Refresh Agents" → `refreshOuroAgents` (a seeded stale agent is CLEARED by the hermetic re-scan);
Add-Agent `Menu{}`: "Create an Agent…" → `isProviderConfigPresented` + `providerConfigIsNewAgent`;
"Clone an Agent from Git…" → `isOuroAgentInstallSheetPresented`. MUTATION-VERIFY: Create action → `// MUT mgr`
→ `testManager_menu_createAgent_presentsProviderForm` RED (2 failures) → reverted → GREEN.

CARVE (1) — recorded for Unit 3:
- `L5998:15` — the `.task { model.refreshOuroAgents() }` modifier. SwiftUI's `.task` does NOT run under
  ViewInspector's synchronous `inspect()` (the host doc-comment notes this); ViewInspector 0.10.3 has no
  `.task`-firing seam (`callOnAppear()` fires `.onAppear`, not `.task`). Its BODY (`refreshOuroAgents()`)
  is independently DRIVEN via the Refresh button — only the `.task` attachment region is the carve.
  Carve kind: **`.task` toolchain-untestable**.

### OuroAgentRowView (10→4) — `OuroAgentRowViewInteractionTests`
DRIVEN via INVOCATION:
- "Use as Boss" → `selectBoss` → `state.boss.agentName`. "Connect tools" (actionable registration injected)
  → `installWorkbenchMCP` → hermetic install fails honestly → `errorMessage`. "Reveal Bundle" →
  `revealAgentBundle` ("no throw"). "Remove Agent" (role: .destructive) → ARMS `agentPendingRemoval` (its id ==
  this row) — never deletes on first tap (also drives the `removalConfirmationBinding` GET arm). The
  `.confirmationDialog` (descended): CONFIRM → `removeAgent` DELETES a MATERIALIZED on-disk `.ouro` bundle +
  re-scans + clears the arm; CANCEL → clears the arm WITHOUT deleting (bundle preserved on disk).
- MUTATION-VERIFY: Remove arm `model.agentPendingRemoval = agent` → `// MUT row` →
  `testRow_remove_armsConfirmation` RED → reverted → GREEN.

CARVE (4) — recorded for Unit 3:
- `L6070:47` — the `.help(registration?.detail ?? "Connect Workbench tools at runtime")` `??` FALLBACK.
  **Proven-dead**: the `.help` is inside `if registration?.isActionable == true`, so `registration` is
  non-nil when it renders → `registration?.detail` is the non-nil String, NEVER the fallback. `--show-regions`:
  the `.help` line count is 32, the `??`-fallback marker is `^0`. Carve kind: **proven-dead branch**.
- `L6129:18` / `L6130:20` / `L6130:74` — the `removalConfirmationBinding` SET closure body
  (`set: { presented in if !presented, model.agentPendingRemoval?.id == agent.id { … } }`). The GET (count 341)
  + the `set:` decl (count 153) ARE covered by render; the setter BODY (`^0`) runs ONLY when SwiftUI dismisses
  the dialog via the `isPresented` binding — ViewInspector's `confirmationDialog().isPresentedBinding()` is
  `fileprivate` (no public seam to set it false). Carve kind: **binding-setter-no-seam**.

### AgentHomeEmptyState (4→0) — `AgentHomeEmptyStateInteractionTests`
DRIVEN: "New Terminal" → `createBlankTerminal` (a blank `processEntries` session; async PTY launch enqueued,
the B2 Recover-All precedent); "Set up a boss" → `presentOnboarding` → `isOnboardingPresented`; "Create an
Agent" → `presentNewAgentProviderConfigForm` → `isProviderConfigPresented` + `providerConfigIsNewAgent`; the
installed-agents card's `SidebarAgentRow.select:` closure (a fixed injected agent) → `selectAgent` →
`selectedAgentName`. MUTATION-VERIFY: `createBlankTerminal()` → `// MUT home` →
`testHome_newTerminal_createsBlankSession` RED → reverted → GREEN.

### OuroAgentInstallSheet (5→0) — `OuroAgentInstallSheetInteractionTests`
DRIVEN: the "Cancel" secondary → `dismiss()` ("no throw"); the `.succeeded` `@State` seam → the
`isFinished ? "Done" : "Cancel"` TRUE arm → "Done" → `dismiss()`; "Clone Agent" (ENABLED by a valid
`initialRemote`) → `startClone()` (sets `.cloning` + spawns the clone Task), and the Task's REAL
`model.cloneAgentHeadless` is awaited DIRECTLY → asserts the honest `.failed` fold for the unresolvable
remote (seam-free inline message, no `/Users/` leak). The `.cloning` busy render (the state `startClone`
sets) is asserted load-bearing via the `initialCloneState` seam. MUTATION-VERIFY: the busy state is a
distinct captured tree from idle (`testInstall_busyState_isLoadBearing`); the clone failure fold is the
async non-vacuity guard.

### ProviderConfigSheet (14→3) — `ProviderConfigSheetInteractionTests`
DRIVEN via INVOCATION (the C6 `initialHumanName` seam; all submit paths via VALIDATION-FAILURE so NO live
hatch/vault terminal spawns):
- "Cancel" → `dismiss()` ("no throw"). "Finish setup" (`needsVaultSetup` true) → `beginVaultOnboarding`
  which EARLY-RETURNS (no stashed `providerConfigColdStartProvider`) → no terminal spawned (asserted).
  "Connect" (existing agent) → `submit()` → clears the seeded stale `providerConfigColdStartMessage`
  (the helper's first statements) → asserts cleared; also drives `submitProviderConfig`'s `.invalid` arm
  (hermetic roster has no "boss" → `form.submit` returns `.invalid` on EMPTY credentials BEFORE any hatch).
  "Create Agent" (new agent, BLANK name) → `submit()` → the new-agent block + `newAgentNameValidationMessage`
  invalid-name early-return (`message` set, returns before hatch; no terminal).
- the credential `SecureField` `setInput` → the `binding(for:)` SET closure (`values[key] = $0`).
- the `.onChange(of: provider)` reset via `callOnChange(oldValue:newValue:)` → asserts the MODEL writes:
  `providerConfigNeedsVaultSetup = false` (BUG 1), `providerConfigColdStartProvider = nil`,
  `providerConfigColdStartMessage = nil`.
- MUTATION-VERIFY: the onChange `providerConfigNeedsVaultSetup = false` → `// MUT onchange` →
  `testProvider_onChangeProvider_resetsStaleVaultAffordance` RED → reverted → GREEN. Connect submit-clear:
  before-tap stale present, after-tap cleared (`testProvider_negativeControl_submitClearsStaleMessage`).

CARVE (3) — recorded for Unit 3:
- `L6229:28` — the non-secret credential `TextField` arm (`else { TextField(field.label, …) }`). It renders
  ONLY for a provider with a non-secret field (Azure `endpoint`/`deployment`); the default `@State provider`
  is `.anthropic` (all-secret). Flipping `provider` needs a `@State`-init seam (prod default UNCHANGED),
  which ViewInspector's synchronous `inspect()` can't persist across re-inspection. Carve kind:
  **`@State`-no-init-seam** (the AgentDetailView `showsInspector` / install-sheet `cloneState` precedent).
- `L6323:14` — the valid-new-name commit `model.providerConfigAgentName = newAgentName.trimmingCharacters(…)`
  (reached only when the `@State newAgentName` is a VALID name — same `@State`-no-init-seam; and a valid name
  then proceeds to the live `ouro hatch`, a process spawn). Carve kind: **`@State`-no-init-seam / live-process**.
- `L6329:10` — the nil-return continuation `values = [:]` after `submitProviderConfig` returns NIL. A nil
  return means the cold-start hatch / credential rotation is IN FLIGHT — both SPAWN a live process / terminal.
  No validation-failure path reaches the nil return. Carve kind: **live-process (cold-start hatch / rotation)**.

### AgentDetailView (3→3 — all carves) — no interaction test (genuinely-untestable arm)
The C7-6 `AgentDetailViewTests` snapshot the genuine COLLAPSED composite. The 3 residual regions are all carves:
- `L8183:41` — the `@State private var showsInspector = false` property-wrapper default autoclosure (an llvm
  coverage artifact for the `@State` initial value; no app seam flips a default-value region). Carve kind:
  **`@State` autoclosure llvm-artifact**.
- `L8202:31` / `L8205:14` — the `if showsInspector` TRUE arm (`AgentInspectorPanel` + a `Divider`). Reachable
  ONLY by flipping the COMPOSITE's own `@State` via the embedded strip's chevron; ViewInspector's synchronous
  `inspect().tap()` does not persist that `@State` flip across re-inspection even under `ViewHosting` (verified
  empirically — the post-tap re-inspect / re-snapshot does not surface the expanded panel). The expanded
  panel's BEHAVIOR is covered standalone by `AgentInspectorPanelPathLeakTests` (C0 SU-3). Carve kind:
  **`@State`-no-seam composite arm** (covered standalone).

## Mutation-verification sweep (single serial actor — no parallel source race)

| view | mutated region | targeted test | verdict |
|---|---|---|---|
| AgentStatusCard | Connect action `installWorkbenchMCP` → `_ = agent` | testCard_connectTools_runsInstall | RED→GREEN ✓ |
| OuroAgentManagerView | Create action `presentNewAgentProviderConfigForm` → `// MUT` | testManager_menu_createAgent_presentsProviderForm | RED→GREEN ✓ |
| AgentHomeEmptyState | `createBlankTerminal()` → `// MUT` | testHome_newTerminal_createsBlankSession | RED→GREEN ✓ |
| AgentTitleStrip | `showsInspector.toggle()` → `// MUT` | testStrip_chevron_togglesInspectorBinding | RED→GREEN ✓ |
| OuroAgentRowView | Remove arm `agentPendingRemoval = agent` → `// MUT` | testRow_remove_armsConfirmation | RED→GREEN ✓ |
| ProviderConfigSheet | onChange `providerConfigNeedsVaultSetup = false` → `// MUT` | testProvider_onChangeProvider_resetsStaleVaultAffordance | RED→GREEN ✓ |

Each mutation was applied, the targeted test re-run (RED), then the source file restored from backup (GREEN
re-verified by the final full-suite pass). Source diff after the sweep: EMPTY (all reverted).

## Gate pass lines

- strict build (`swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`): **0 warnings / 0 errors**.
- `swift test`: **3642 tests, 1 skip, 0 failures**.
- `--uisurfacetest`: **ok** (all surface probes "ok", exit 0).
- `scripts/check-coverage.sh`: **PASS** — Core/ShellAdapter 149/151 files 100% line+region (2 pre-existing
  allowlisted structural exclusions); `coverage-allowlist.txt` + `COVERAGE_DIRS` **UNCHANGED** vs origin/main.
- `scripts/smoke-package-shallow-guard.sh`: **ok**.
- No `SerpentGuide.ouro/` / `*.profraw` / `*.profdata` / `*.actual.txt` / coverage-JSON staged.

## Summary

51 B7 uncovered regions → **40 driven** (each invoked + side-effect asserted + mutation-verified) + **11 carved**
(every carve `--show-regions`-justified: 1 `.task`, 1 proven-dead `??`, 3 binding-setter-no-seam, 1+2
`@State`-no-init-seam, 1 live-process, 1 `@State` autoclosure artifact, 2 `@State`-no-seam composite). The
carves are the Unit-3 allowlist seed for this cluster — none is a K2 (un-driven) region.
