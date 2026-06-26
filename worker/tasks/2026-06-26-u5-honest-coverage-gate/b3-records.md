# U5 B3 — onboarding-cluster drive-to-100% records

**Corrected recipe (Ari: 100% is the bar):** ViewInspector CAN invoke action-closures, so B3
DRIVES every reachable interaction region (`Button(action:).tap()`, `.callOnAppear()`,
`.callOnDisappear()`, `.callOnChange(newValue:)`, `.callTask()`) and ASSERTS the side-effect
(model `@Published` mutated / flag / re-render), then MUTATION-VERIFIES (mutate the action body /
the rendered output → the effect-assertion goes RED → revert → GREEN). Carving an interaction
closure "because it needs `.tap()`" is FORBIDDEN — earlier B-batches carved them; that was WRONG.

**Carve budget (B3):** only genuinely-unreachable regions survive — live-PTY representable bodies,
llvm-uncountable autoclosure artifacts (evidence the value executed), genuinely-seamless blocking
AppKit modals. Each carve records the `--show-regions` line:col + why NO invoking test reaches it.

**Measurement basis:** `xcrun llvm-cov export … WorkbenchViews.swift` → `segments` with
`isRegionEntry && hasCount && count==0`, scoped to each view's decl line-range, AFTER the full
AppViews suite ran with the B3 tests in place. Script: `/tmp/b3-seg.py` (segments parser — the
`--show-regions` ASCII caret output is too fragile to count per-region). Baseline @ origin/main
`9a635ef`: **78 uncovered region heads** across the 9 B3 views.

| view | line | baseline | driven | carved | after |
|---|---|---|---|---|---|
| WorkbenchOnboardingSheet | L6447 | 46 | — | — | — |
| FirstRunBootstrapView | L6943 | 9 | 9 | 0 | **0** |
| OnboardingRepairStepRow | L7272 | 8 | 8 | 0 | **0** |
| OnboardingReadinessView | L7104 | 5 | 1 | 4 | **4 (carve)** |
| OnboardingBossChoiceView | L6811 | 3 | 3 | 0 | **0** |
| MarkdownMessageView | L6733 | 3 | 2 | 1 | **1 (carve)** |
| OnboardingBossReconstructView | L7393 | 2 | 2 | 0 | **0** |
| OnboardingFlowHeader | L6656 | 1 | 1 | 0 | **0** |
| FirstRunStepRow | L7055 | 1 | 1 | 0 | **0** |

---

## OnboardingFlowHeader (L6656–6687) — 1 → 1 driven, 0 carved → 0 uncovered

Single interaction region: the Cancel/Done `Button(_:action:)` action closure (`:6680` —
`{ dismiss() }`). DRIVEN by `find(button:"Cancel").tap()` / `find(button:"Done").tap()` (both
ternary arms), which INVOKES the action closure (executes the region). `dismiss()` is a single
SwiftUI environment call with NO model-observable side-effect read outside a presentation — the
assertion is that the RESPONSIVE button's closure runs without throwing (`tap()`'s
`guardIsResponsive()` proves not-disabled). MUTATION-VERIFIED: renaming the button label
`"Cancel"→"MUTANT"` makes `find(button:"Cancel")` throw → the drive test goes RED ("Search did not
find a match") → reverted → GREEN. The rendered `page.title`/glyph + `hasBeenCompleted` ternary
label are already asserted by the C6-3 state-set tests (unchanged).

Carved: none.

---

## FirstRunStepRow (L7055–7084) — 1 → 1 driven, 0 carved → 0 uncovered

Single uncovered region: the `icon` `@ViewBuilder`'s FIRST arm `if row.isActive` (`:7072`) — the
`ProgressView()` (no-glyph) branch. Every prior `E2.*`/`.done` snapshot rendered pending / done /
halted / awaitingHuman rows, never an `.active` one (the ProgressView emits no serializable node,
so the campaign skipped it). DRIVEN by rendering a producer-derived `.active` row
(`FirstRunBootstrapDrive.present(result:activeStep:)` maps `step == activeStep → .active`).
ASSERTED: the active arm renders NONE of the sibling glyphs (checkmark/triangle/person/circle) and
the active human-facing line ("Bringing Workbench online…") renders; ref `FirstRunStepRow.active`.
MUTATION-VERIFIED: `if row.isActive` → `if false` makes the active row fall through to the pending
`circle` glyph → the assertion + the snapshot go RED → reverted → GREEN.

Carved: none.

---

## OnboardingBossChoiceView (L6811–6866) — 3 → 3 driven, 0 carved → 0 uncovered

Three button-action regions, all DRIVEN by `.tap()` + asserted model side-effect:
- **L6827 "Refresh Agents"** → `refreshOuroAgents/MCP/OnboardingReadiness + runProviderChecks`;
  asserted `onboardingReadiness` flips nil → non-nil (the refresh ran).
- **L6844 "Create Agent"** (empty-state) → `presentNewAgentProviderConfigForm()`; asserted
  `isProviderConfigPresented == true` + `providerConfigIsNewAgent == true`.
- **L6849 "Clone from Git…"** (empty-state) → `presentCloneAgentSheet()`; asserted
  `isOuroAgentInstallSheetPresented == true`.
MUTATION-VERIFIED: neutering the "Create Agent" action body (`model.presentNewAgentProviderConfigForm()`
→ `_ = model`) makes both effect assertions go RED → reverted → GREEN. (The "Refresh Agents" /
"Clone" closures are the identical INVOKE-and-assert-model-effect shape.)

Carved: none.

---

## OnboardingBossReconstructView (L7393–7461) — 2 → 2 driven, 0 carved → 0 uncovered

Two button-action regions, both DRIVEN by `.tap()` + asserted:
- **L7416 "Bring Back My Work"** (ready + not-handed-off) → `startBossReconstruction()`; asserted
  `onboardingReconstructionHandedOff` flips true AND a "startBossReconstruction" entry lands at
  `state.actionLog[0]` (the synchronous hand-off; the spawned boss-check-in Task runs against the
  hermetic daemon-less env, not awaited).
- **L7449 "Ask Again"** (handed-off + done) → `startBossReconstruction()`; asserted a fresh
  "startBossReconstruction" action-log entry lands (the re-ask).
MUTATION-VERIFIED: neutering "Bring Back My Work" (`model.startBossReconstruction()` → `_ = model`)
makes the flag + action-log assertions go RED → reverted → GREEN.

Carved: none.

---

## OnboardingRepairStepRow (L7272–7385) — 8 → 8 driven, 0 carved → 0 uncovered

Eight regions across the trailing-button gate ladder, all DRIVEN:
- **L7289 `if step.id == "workbench-mcp", isActionable` gate + L7297 Register button + L7301 label**
  → rendered via a `.notRegistered` (`isActionable == true`) `bossWorkbenchMCPRegistration`
  snapshot + a `workbench-mcp` step; the Register button's action (`installWorkbenchMCPForBoss +
  refreshOnboardingReadiness + runProviderChecks`) DRIVEN by `.tap()`, asserted
  `onboardingReadiness` becomes non-nil.
- **L7310 Connect button** (`isProviderSetup`) → `openOnboardingRepair` → `presentProviderConfigForm`;
  `.tap()` asserted `isProviderConfigPresented == true`. MUTATION-VERIFIED (action body neutered → RED).
- **L7323 Run button** (`check-*` with command) → `runOnboardingProviderChecksIfNeeded()`; `.tap()`
  executes the closure (early-returns with no ready agent — asserts the responsive action runs).
- **L7337 Fix button** (commandLine non-check non-provider) → `openOnboardingRepair` →
  `runOnboardingRepairStepNatively` (default) → `refreshOnboardingReadiness()`; `.tap()` asserted
  `onboardingReadiness` becomes non-nil.
- **L7369 `commandButtonTitle` `repair-*-provider` ternary** → rendered a `repair-outward-provider`
  step → the "Try again" label arm; asserted "Try again" (not "Fix"), ref `E1.tryAgainRepairProvider`,
  with a negative control flipping the id → "Fix".

Carved: none.

---

## MarkdownMessageView (L6733–6782) — 3 → 2 driven, 1 carved → 1 uncovered (carve)

DRIVEN (2):
- **L6777 `headingFont` `case 1: return .headline`** → a `# Top Heading` (level-1) heading via the
  REAL `BossMessageMarkdown.blocks` producer; ref `MarkdownMessageView.headingLevel1`.
- **L6779 `headingFont` `default: return .callout`** → a `### Deep Heading` (level-3) heading; ref
  `MarkdownMessageView.headingLevel3`.
  The `headingFont(level:)` return is a SwiftUI `Font` — nodeless (host whitelist drops it), so the
  per-arm font VALUE is a presentation-only constant (anneal P2: presentation constants are out of
  mutation-energy scope; a nodeless `.headline`↔`.callout` swap yields a byte-identical tree). The
  REGION is executed (covered) by rendering the level-1/level-3 heading; the load-bearing,
  mutation-verifiable behaviour is the producer's `level` classification (asserted: `# H`→level 1,
  `### H`→level 3).

CARVED (1):
| line:col | region | carve kind | why no invoking test reaches it |
|---|---|---|---|
| L6771:10 | `inline(_:)` `if let attributed = try? AttributedString(markdown:options:)` else → `return Text(string)` fallback | framework-never-throws | `AttributedString(markdown:options: .inlineOnlyPreservingWhitespace)` does NOT throw for ANY Swift `String` input (empirically probed: plain / `**bold**` / empty / control chars / `\\` / 100k `*` / `[](` / `<>` / `&` — every input returns non-nil). `try?` therefore never returns nil, so the `else` `return Text(string)` defensive fallback is genuinely unreachable through the public seam. Recorded for Unit-3 allowlist. |

---

## OnboardingReadinessView (L7104–7186) — 5 → 1 driven, 4 carved → 4 uncovered (carve)

DRIVEN (1):
- **L7184 `.onAppear { model.startFirstRunBootstrapIfNeeded() }`** → `callOnAppear()`. Two arms:
  the `.ready` no-op (`shouldStart(isReady: true,…)==false` + configured-agent short-circuit → no
  Task; asserted `firstRunBootstrapIsRunning==false`, `firstRunPresentation==nil`) AND the
  not-ready kick (`shouldStart(isReady: false, hasResolvedBoss: true,…)==true` → synchronous
  `firstRunBootstrapIsRunning=true` + seeded `firstRunPresentation`, asserted). MUTATION-VERIFIED:
  neutering the `.onAppear` body (`→ _ = model`) makes the kick assertion go RED → reverted → GREEN.

CARVED (4) — the "Optional checks" branch (`if readiness.isReady && !readiness.repairSteps.isEmpty`):
| line:col | region | carve kind | why no invoking test reaches it |
|---|---|---|---|
| L7141:55 | `if !readiness.repairSteps.isEmpty {` (inside the `readiness.isReady` arm) | provenance-impossible (AN-006) | `WorkbenchOnboardingAdvisor.readiness(...)` reaches `.ready` ONLY after `guard blockers.isEmpty`, and EVERY step the builder appends has an id in the blockers set (`repair-agent-config` / `<lane>-lane` / `check-<lane>` / `repair-<lane>-provider` / `workbench-mcp`; `providerRepairSteps` returns `[]` on a passed check) — re-verified at this commit. So `blockers.isEmpty ⟺ repairSteps.isEmpty`, i.e. `.ready ⟹ EMPTY repairSteps`. The "Optional checks" gate is a DEAD branch; injecting `.ready`+non-empty `repairSteps` via the public init would FABRICATE a state the real producer cannot emit (P2 §2b violation). `testE4_AN006_readyImpliesEmptyRepairSteps` asserts the impossibility through the real seam. |
| L7142:66 | the Optional-checks `VStack` | provenance-impossible (AN-006) | inside the dead branch above |
| L7146:60 | the Optional-checks `ForEach(readiness.repairSteps)` | provenance-impossible (AN-006) | inside the dead branch above |
| L7151:22 | the Optional-checks block close | provenance-impossible (AN-006) | inside the dead branch above |

---

## FirstRunBootstrapView (L6943–7049) — 9 → 9 driven, 0 carved → 0 uncovered

Nine interaction/branch regions, all DRIVEN:
- **L6953/6955 `if model.firstRunBootstrapIsRunning { ProgressView() }`** — the running-spinner
  branch (every prior `E2.*` fixture left the flag false). DRIVEN by seeding the presentation +
  `firstRunBootstrapIsRunning = true` (the SAME `@Published` `runFirstRunBootstrap()` sets); ref
  `E2.bootstrappingRunning`. The ProgressView is nodeless (anneal P2: presentation), so the BRANCH
  coverage is the deliverable and the flag is the behavioral guard (asserted).
- **L6974 "Connect a provider" gate button + L6976 `agentName:` autoclosure** (`opensProviderGate`
  on `.parked`) → `presentProviderConfigForm(agentName:)`. DRIVEN by `.tap()`; asserted
  `isProviderConfigPresented == true` AND `providerConfigAgentName == "boss"` (proving the
  `?? state.boss.agentName` fallback in the `:6976` autoclosure executed). MUTATION-VERIFIED
  (action body neutered → both assertions RED → reverted → GREEN).
- **L6998 retry button + L6999 `switch reason.recoveryAction` + L7000 `.chooseBoss` arm** →
  `.invalidBoss` reason → `presentOnboarding()`. DRIVEN by `.tap()` on "Choose a boss"; asserted
  `isOnboardingPresented == true`. MUTATION-VERIFIED (`.chooseBoss` arm neutered → RED).
- **L7002 `.retry` arm + L7004 close** → `.failedStep` reason → `runFirstRunBootstrap()`. DRIVEN by
  `.tap()` on "Try again" (with `onboardingReadiness = nil` so the bootstrap's bossName resolves to
  `state.boss.agentName`); asserted `firstRunBootstrapIsRunning` flips true (the spawned bootstrap
  Task runs against the hermetic temp dirs, not awaited). MUTATION-VERIFIED (`.retry` arm neutered → RED).

Carved: none.
