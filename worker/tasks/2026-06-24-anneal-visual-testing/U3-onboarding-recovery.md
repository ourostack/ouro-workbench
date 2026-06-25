# Doing: U3 — Surfaces C/D/E (inline editors · recovery+archived · onboarding)

**Status**: drafting → READY_FOR_EXECUTION (set after the conversion passes + the fresh review gate)
**Execution Mode**: spawn (one work-doer sub-agent per sub-unit; strict TDD; one commit per sub-unit; serialized merges onto the branch; no PR — the campaign merges the branch)
**Created**: 2026-06-25 09:22
**Planning**: this doc IS the planning doc, converted in place (the campaign convention — see U1/U2). The planning header/goal/scope/decisions are RETAINED below as the authoritative context; the work-unit decomposition + execution sections are appended.
**Campaign / Journal**: ../2026-06-24-anneal-visual-testing.md  (the authoritative anneal journal — this is its U3 plan)
**Artifacts**: ./U3-onboarding-recovery/  (spikes, per-surface coverage snapshots, review records, gate logs)
**Branch**: feat/anneal-u3-onboarding-recovery (off origin/main @ 976610d, the U2 merge `#293`). No PR.
**Harness (LIVE on main, the proven pattern)**: `Tests/OuroWorkbenchAppViewsTests/{AssertViewSnapshot,ViewSnapshotHost,ViewTreeSerializer,ViewSnapshotNode,ViewSnapshotStore}.swift` + the U2 surface tests `{BossProposalCardStateSetTests,SidebarSurfaceStateSetTests,TabStripSurfaceStateSetTests,TerminalAgentRowRunningLeafTests}.swift`.

## Execution Mode

- **spawn** — each sub-unit (PR-scoped) is driven by its own work-doer pass, strict TDD, one commit. Merges are serialized onto this branch (no PR). NEVER run two build-lock-holding agents in one checkout (anneal §4: worktree-isolate / static-only / stagger). The fresh review gate (P5) runs before READY and again pre-merge per the campaign.
- Why not `direct`: each surface (C/D/E) and each E sub-surface warrants an isolated, individually-reviewable, revertible commit — anneal demands "every fix is its own PR, independently revertible."

## Objective (from planning Goal)

Use the LIVE ViewInspector view-snapshot harness to snapshot the REAL surfaces C (inline editors), D (recovery + archived), and E (onboarding) at their COMPLETE enumerated state-sets — each fixture provenance-built via the real model seam, each surface with ≥1 mutation-verified negative control, every committed reference deterministic (P3) and minimal/agent-legible (P4b). This grows the views-lib coverage toward the eventual U4 coverage-gate, WITHOUT gating the views lib this unit.

**DO NOT include time estimates (hours/days).**

## Scope

### In Scope

- **C. Inline editors** (`InlineRenameEditor`, now `:3169`): editing-workspace / editing-tab / empty-whitespace draft (no-op) / prefilled-valid; boundary — a whitespace commit closes WITHOUT writing an override (`WorkspaceRenameCommit.resolve` → `.noop`).
- **D. Archived + Recovery** (`RecoverySheet` `:821`, `NeedsYouEntryRow` `:941`, `RecoverableEntryRow` `:1018`, + the sidebar Archived section in `WorkbenchSidebarView` `:2923`): nothing / needs-you-only / auto:one (no Recover-All) / auto:many (Recover-All shown) / both; boundary — trust-fix vs Start-fresh; lossless-reattach pill vs not.
- **E. Onboarding** (`OnboardingBossChoiceView` `:6670`, `OnboardingReadinessView` `:6955`, `FirstRunBootstrapView` `:6800` + `FirstRunMode`, `OnboardingRepairStepRow` `:7117`): boss-choice {none/one/many/selected/unusable}; readiness {nil/not-ready/ready/ready+optional/in-progress}; first-run {bootstrapping/parked/needsAttention/agentDriven/nil}; repair-step actor variants {agentRunnable/humanRequired/humanChoice}.
- Per surface: every fixture provenance-built via the real seam (P2); ≥1 mutation-verified negative control (P2); determinism (P3, incl. AN-001 temp `agentBundlesURL` injection in EVERY VM fixture); minimal/agent-legible (P4b); non-redundant (P4e); complete enumerated state-set (P4c).
- A per-surface a11y-identifier audit (selective policy D-U2-2): add `.accessibilityIdentifier` ONLY where two serialized nodes would otherwise be byte-identical AND defeat a negative control; else "none needed."
- Record the running views-lib coverage % as each surface lands (artifact, input to U4).
- One commit per sub-unit; NO AI attribution; `SerpentGuide.ouro/` never staged. No PR (the campaign merges the branch).
- A fresh, unbiased sub-agent review gate (no inherited context) before READY_FOR_EXECUTION — operator is asleep, so this substitutes for human signoff.

### Out of Scope

- **Coverage-gating the views lib** (`COVERAGE_DIRS`/allowlist UNCHANGED this unit — that is the campaign's final unit U4).
- Retiring grep-guards (P7 — tracks to U4 as coverage lands; ~268 sites stay green this unit).
- The agent-inventory pane that DOES render `bundlePath`/`configPath` (`:8145`/`:8156`) — a DIFFERENT view, not a C/D/E surface; out of scope.
- `OnboardingBossReconstructView` (the `.importWork` page, `:6567`) — legacy scan/arrange removed; not a named U3 surface.
- Any product behavior change. The ONLY conceivable product-source touch this unit is a selective `.accessibilityIdentifier` IF the a11y audit proves one is needed (expected: none, per the U2 evidence) — and SU0-style product touches (the `TimelineView` clock) are already done in U2; C/D/E embed NO clock reads (verified — see Determinism landmines).
- Fixing the AN-001 SOURCE defect (still open; mitigated in-fixture).
- ViewInspector dep changes (U5, deferred).

## Completion Criteria

- [ ] C/D/E each have a COMPLETE enumerated state-set committed as non-redundant references (P4c/P4e).
- [ ] Every fixture provenance-built via the real seam (P2); NEVER hand-assembled serializer output / model state.
- [ ] ≥1 MUTATION-VERIFIED negative control per surface (breaking a real guard → the snapshot test goes RED). Per the upgraded skill, the negative control corresponds to breaking a real guard, not just a fixture tweak.
- [ ] Determinism (P3): fixed clock/locale/UTC-TZ; zero machine paths; twice-run byte-identical; no `/Users/…`, `Date()`, `.now`, or `UUID()` in any committed reference. AN-001 temp `agentBundlesURL` injected (into BOTH `BossWorkbenchMCPRegistrar` AND `OuroAgentInventory`) in EVERY VM fixture.
- [ ] Each enumerated state that CANNOT be provenance-built via a real seam is moved to a standalone leaf OR recorded as an unreachable observation — NEVER fabricated.
- [ ] a11y-identifier decision recorded per surface ("none needed" or the minimal additions, with rationale).
- [ ] Running views-lib coverage % recorded per surface (artifact).
- [ ] 100% test coverage on all NEW code (any harness-side helpers added). The views lib is NOT gated this unit.
- [ ] Gates: strict build/test `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` 0 warn / 0 fail (our products); `--uisurfacetest` green; `Scripts/check-coverage.sh` green with `COVERAGE_DIRS` + allowlist UNCHANGED; ~268 grep-guards green/unchanged.
- [ ] One commit per sub-unit. NO AI attribution. `SerpentGuide.ouro/` never staged.
- [ ] All tests pass; no warnings.
- [ ] Fresh unbiased sub-agent review gate run; zero surviving CRITICAL/HIGH (P5) before READY.

## Code Coverage Requirements

**MANDATORY: 100% coverage on all NEW code** (any harness-side helper added; e.g. a `ContentUnavailableView`/system-view extraction tweak if the spike proves one is needed).
- No `[ExcludeFromCodeCoverage]`-equivalent on new code.
- All branches covered (each enumerated surface state; the editable/static field flips; the trust-fix vs Start-fresh branch; the lossless-reattach pill branch; each FirstRunMode branch; each repair-actor branch).
- All error paths tested (ViewInspector traversal throw → reported as a test failure, not a crash).
- Edge cases: empty/one/many; nil vs present; whitespace draft; ready vs not-ready; selected vs unusable.
- **Scope note (do NOT gate the views lib yet):** `COVERAGE_DIRS` stays `{OuroWorkbenchCore, OuroWorkbenchShellAdapter}`; allowlist unchanged. The views lib joins the gate at U4. U3 GROWS snapshot coverage; record the running views-lib coverage % per surface.

## Open Questions

- [ ] **Q1 — `ContentUnavailableView` extraction (D, "nothing-to-recover" state).** `RecoverySheet`'s empty state renders a SYSTEM `ContentUnavailableView("Nothing to recover", systemImage:…, description:…)` (`:857`). Does ViewInspector's `findAll` descend its title/description `Text` so the serializer extracts them? If not, the "nothing" reference must assert on a stable alternative (the `Text("Recovery")` header + the absence of section rows). RESOLVE in the D spike (SU-D0). Reversible default: if the system view doesn't extract cleanly, assert the surrounding stable nodes + the absence of the "Needs you"/"Ready to recover" section headers, and record the system-view-opacity observation.
- [ ] **Q2 — `@Environment(\.dismiss)` + `.onAppear`/`.task` under the no-`ViewHosting` `inspect()` path.** `RecoverySheet` has `@Environment(\.dismiss)` (`:823`); `OnboardingReadinessView` has `.onAppear { startFirstRunBootstrapIfNeeded() }` (`:7035`); the sidebar has a `.task`. PRECEDENT: U2 successfully snapshotted `BossProposalCardList` (which has a `.task { loadPendingProposals() }`) and `WorkbenchSidebarView` (which has a `.task`) — so the synchronous `inspect()` path does NOT fire `.task`/`.onAppear`, and `@Environment(\.dismiss)` defaults to a no-op when unhosted. CONFIRM in the first spike of each surface; STOP-and-surface if any descended node needs hosting/a live action (that would be an out-of-U3 view-source touch). Reversible default: rely on the U2 precedent; verify empirically per surface before recording any reference.
- [ ] **Q3 — Boss-choice provenance: inject `model.ouroAgents` directly vs write fixture bundles into the temp `agentBundlesURL`.** Boss-choice names derive from `bossAgentChoices = ouroAgents.map(\.name) + bossDashboard?.knownAgentNames + [state.boss.agentName]` (`:12679`). Two seams: (a) set `model.ouroAgents = [OuroAgentRecord(...)]` directly with FIXED records (clean — no temp-path leak, no FS write; `ouroAgents` is `@Published`, the same property `refreshOuroAgents()` writes); (b) inject `OuroAgentInventory(agentBundlesURL: temp)` + write fixture `*.ouro` bundle dirs so `scan()` returns them. **Reversible default: (a) direct `ouroAgents` injection** — it is the same published seam the live scanner writes, avoids a temp-path leak risk (`OuroAgentRecord.bundlePath`/`configPath` are absolute, though the boss-choice surface does NOT render them — confirmed), and is hermetic. AN-001 temp `agentBundlesURL` injection is STILL mandatory regardless, so a stray `refreshOuroAgents()` can't scan the real home. The SU-E0 spike confirms (a) produces the right `onboardingBossChoices`; falls back to (b) only if a derivation reads a field direct-injection can't set. Record the chosen seam.
- [ ] **Q4 — Readiness / first-run provenance: drive the pure Core producer vs set the `@Published` directly.** `onboardingReadiness` (`@Published`, `:10888`) is produced by the pure `WorkbenchOnboardingAdvisor.readiness(boss:agents:mcpRegistration:providerChecks:daemonLiveness:)` (`Onboarding.swift:189`); `firstRunPresentation` (`@Published`, `:10624`) by the pure `FirstRunBootstrapDrive.presentIdle()` / `.present(result:activeStep:)` (`FirstRunBootstrapDrive.swift:324/338`). **Reversible default: build the value via the pure Core PRODUCER, then assign to the `@Published`** (e.g. `model.onboardingReadiness = WorkbenchOnboardingAdvisor().readiness(boss:…, agents:…)`; `model.firstRunPresentation = FirstRunBootstrapDrive(...).present(result: BootstrapResult(phase: .parkedAwaitingProviderConfig), …)`). This is provenance-honest (the real Core producer maps inputs→presentation; the test does not hand-assemble the struct) AND avoids invoking the live async `runFirstRunBootstrap()` (which spawns real effects). The `@Published` is the genuine VM seam the producer writes. Record the exact producer call per state. (Directly constructing the `OnboardingReadiness`/`FirstRunBootstrapPresentation` struct is the FALLBACK only if a state can't be produced through the advisor/drive — none is expected; the E agent found no provenance impossibility.)
- [ ] **Q5 — Sub-unit count for E (the complex surface).** E decomposes cleanly into 4 leaf-surfaces (boss-choice / readiness / first-run / repair-step). Are these 4 separate sub-PRs, or fewer fatter ones? **Reversible default: 4 sub-units** (one commit each) for independent reviewability + revertibility (anneal "every fix its own PR"). Readiness embeds FirstRunBootstrapView (not-ready branch) and OnboardingRepairStepRow, so order them: repair-step → first-run → readiness (readiness depends on both being landed), boss-choice independent. The doer may merge two if a sub-surface is trivially small, recording why.
- [ ] **Q6 — a11y-identifier audit per surface (D especially).** Recovery rows (`NeedsYouEntryRow`/`RecoverableEntryRow`) carry NO `.accessibilityLabel` (unlike A/B's computed labels) — node identity for repeated rows rests on distinct `entry.name` + reason + `launchCommand` Text nodes. **Reversible default: use DISTINCT `entry.name`s in "many" fixtures** (as U2 did for tabs) → expect "none needed"; add a minimal identifier ONLY if two rows would otherwise serialize byte-identically AND defeat a negative control. Audit per surface; record the decision.

## Decisions Made

- **D-U3-1 — Reuse the LIVE U2 harness unchanged where possible.** `assertViewSnapshot(of:named:)` + `ViewSnapshotHost` (with AN-002 `input()` + AN-004 `.help`-drop + UTC-TZ pin + AN-001 hermetic-inventory pattern) are on `main` @ 976610d and proven. U3 adds only fixtures + tests; a harness-side change is allowed ONLY if a spike proves a surface needs it (e.g. Q1 `ContentUnavailableView`), and it must be 100%-covered + test-only.
- **D-U3-2 — Provenance via the REAL seam, hermetic (P2 + AN-001).** D via `WorkbenchStore.save(state)` → fresh VM whose load derives `summary.recoveryPlans` through `RecoveryPlanner`, with `model.liveScreenSessionNames` set for the `.reattach` case. E via the pure Core producers (`WorkbenchOnboardingAdvisor.readiness` / `FirstRunBootstrapDrive.present`) assigned to the `@Published`, with `model.ouroAgents` injected for boss-choice. C via `model.beginRename(...)` + `inlineRename.draft`. EVERY VM injects a temp `agentBundlesURL` into BOTH `BossWorkbenchMCPRegistrar` AND `OuroAgentInventory` (AN-001 — closes the home-scan leak that bit U2 SU3).
- **D-U3-3 — Negative controls are MUTATION-verified (upgraded skill P2).** Each surface's negative control breaks a REAL guard and the snapshot test must go RED: D — flip a `ProcessRun.status` (`.needsRecovery`↔`.manualActionNeeded`) or `liveScreenSessionNames` membership → the recovery section / lossless pill flips; flip `entry.trust` → trust-fix↔Start-fresh flips. E — flip `FirstRunMode`/`BootstrapPhase` → mode pill/icon/rows flip; flip `OnboardingReadinessState` → ready↔not-ready flips; flip `OnboardingRepairActor` → the actor pill flips. C — set a whitespace draft + commit → assert NO override is written (the `.noop` boundary) AND the editor tree differs from a valid-prefill tree. Per the skill, prove load-bearing by re-applying the exact mutation (test RED) then reverting byte-identically (test GREEN).
- **D-U3-4 — Determinism (P3): C/D/E embed NO clock reads (verified) → no new SU0-style product-source touch.** The U2 `TimelineView` injectable-clock seam already covers the only clock sites (`ElapsedTimePill`/`DecisionInboxSheet`/`TerminalAgentRow` a11y), and none of C/D/E renders an elapsed/`Date()` value. The remaining determinism levers are the existing host pins (locale `en_US_POSIX`, UTC TZ, `.help`-drop) + AN-001. The one machine-specific input across C/D/E is the boss-choice/readiness AGENT NAMES (from the inventory scan), controlled by the AN-001 injection + fixed fixture records. See Determinism landmines.
- **D-U3-5 — Coverage NOT gated this unit (D-U2-5 carried forward).** `COVERAGE_DIRS` + allowlist UNCHANGED. Record running views-lib coverage % per surface as an artifact (continues the 7.70%-region post-U2 progression).
- **D-U3-6 — Selective a11y identifiers (D-U2-2 carried forward).** Add `.accessibilityIdentifier` ONLY where a byte-identical-node ambiguity defeats a negative control; default "none needed" with distinct fixture names.
- **D-U3-7 — No PR; autonomous; fresh review gate substitutes for signoff.** Operator asleep → run an unbiased, no-inherited-context sub-agent adversarial review before READY (P5); resolve all CRITICAL/HIGH first. For genuine ambiguity, pick the reversible default and record it (above).

## TDD Requirements

**Strict TDD — no exceptions (the snapshot variant, proven in U2):**
1. **Tests first**: write the failing `assertViewSnapshot` test BEFORE recording any reference (the test asserts against a not-yet-recorded reference → RED on the missing file). For a spike or a harness-side helper, classic red→green.
2. **Verify failure** (red).
3. **Minimal implementation / RECORD**: record the reference (`OURO_SNAPSHOT_RECORD=1`) ONLY after eyeballing the tree is honest — provenance (P2: built via the real seam) + no machine-path/clock/UUID/agent-name leak (P3). Then re-run in COMPARE mode.
4. **Verify pass** (green) + twice-run byte-identical + a no-`/Users/` scan.
5. **Refactor**, keep green.
6. **No skipping**: never record a reference asserting a state the real seam can't produce (vacuous test — the P2 trap); never implement without a failing test.

**Negative controls are MUTATION-verified (D-U3-3 / upgraded skill P2):** each surface's negative control breaks a REAL guard → the snapshot test goes RED; prove load-bearing by re-applying the exact mutation (RED) then reverting byte-identically (GREEN). A test-only negative-control sub-unit is gated by its mutation, not necessarily a reviewer panel.

## Pre-execution facts (validated @ 976610d)

All product line refs in **Context / References** were re-located + validated against `Sources/OuroWorkbenchAppViews/WorkbenchViewsAndModel.swift` @ 976610d (the campaign's §Surfaces refs are STALE by ~100–120 lines post-extraction). The Core seam types (`RecoveryPlanner`/`RecoveryDigest`/`WorkbenchOnboardingAdvisor`/`FirstRunBootstrapDrive`/`FirstRunMode`/`OnboardingRepairActor`/`OnboardingReadiness`) and the settable `@Published` seams (`liveScreenSessionNames`/`ouroAgents`/`onboardingReadiness`/`firstRunPresentation`/`inlineRename`) were read first-hand. **Provenance-impossibility scan result: NONE** (see Notes) — every enumerated state is reachable through a real seam; no leaf carve-out or unreachable-observation is required this unit (unlike U2's C1).

## Sub-unit decomposition (PR-scoped) + dependency graph

```
SU-C  (Inline editors — InlineRenameEditor)                         ── independent
SU-D  (Recovery + Archived — RecoverySheet/NeedsYou/Recoverable + sidebar Archived)  ── independent
       └─ SU-D0 spike (ContentUnavailableView extraction Q1) folds into SU-D
E (the complex surface — 4 sub-units, ordered by embedding dependency):
  SU-E1 (Repair-step row — OnboardingRepairStepRow; actor variants)  ── independent leaf
  SU-E2 (First-run — FirstRunBootstrapView + FirstRunMode)           ── independent
  SU-E3 (Boss-choice — OnboardingBossChoiceView/Row)                 ── independent (needs the ouroAgents-injection seam, Q3)
  SU-E4 (Readiness — OnboardingReadinessView)        ── DEPENDS ON SU-E1 + SU-E2 (embeds both in its not-ready branch)
```

- **Independent (fan-out-able, but serialize the merges):** SU-C, SU-D, SU-E1, SU-E2, SU-E3.
- **Critical path:** SU-E1 + SU-E2 → SU-E4 (readiness's not-ready branch embeds `FirstRunBootstrapView` + `OnboardingRepairStepRow`; landing those first lets SU-E4's references be stable and lets SU-E4 reuse their fixtures).
- **Merge order on-branch:** SU-C, SU-D, SU-E1, SU-E2, SU-E3, SU-E4 (E-leaves before E-readiness). Each is one commit; reviewers staggered/worktree-isolated (never two build-lock holders in one checkout).
- **Spikes** (each a make-or-break gate folded into its sub-unit's first phase, deleted after): SU-D0 = Q1 (`ContentUnavailableView` extraction) + Q2 (`@Environment(\.dismiss)` / `.task` no-fire); SU-E0 (in SU-E3) = Q3 (boss-choice injection seam) + Q4 (producer-vs-direct for readiness/first-run) + Q2 (`.onAppear` no-fire). A spike's throwaway test is deleted; its verdict is recorded in `./U3-onboarding-recovery/`.

## Work Units

### Legend
⬜ Not started · 🔄 In progress · ✅ Done · ❌ Blocked

**Every unit header starts with a status emoji (⬜ for new units).**

---

### ⬜ SU-C: Inline editors (`InlineRenameEditor`) — full enumerated state-set

Independent. Provenance via `model.beginRename(target:prefill:)` + `model.inlineRename.draft` (the same seam ⇧⌘R drives; `InlineRenameState`, Core). The editor is a VM-bound view; build a hermetic VM (AN-001 temp `agentBundlesURL`) and put it into rename mode, OR snapshot the editor in isolation by constructing a VM whose `inlineRename` carries the target+draft. Note: U2 already snapshotted the editor EMBEDDED (`A.renameInProgress`, `B.tabRenameInProgress`); SU-C covers the editor's OWN enumerated states (workspace vs tab target; empty-whitespace draft; prefilled-valid) + the no-op boundary.

#### ⬜ SU-C.a: state-set tests — FIRST (red)
**What**: Write FAILING `assertViewSnapshot` tests for the COMPLETE C state-set (each provenance-built via `beginRename` + a fixed `draft`):
- `C.editingWorkspace` — `beginRename(.workspace(id), prefill: "Frontend")`; editor renders the "Name" TextField bound to the draft + the caption + `accessibilityLabel("Rename")`.
- `C.editingTab` — `beginRename(.tab(id), prefill: "build")`; same editor shape, tab target.
- `C.emptyWhitespaceDraft` — draft set to whitespace (e.g. `"   "`); the editor renders the (whitespace) draft; this is the no-op-on-commit case.
- `C.prefilledValid` — a valid non-empty distinct draft (e.g. `"Renamed Frontend"`).
- Choose the MINIMAL non-redundant set (P4e): editing-workspace vs editing-tab may serialize identically IF the editor tree doesn't encode the target — VERIFY; if identical, the "editing-tab" is covered by the embedded U2 `B.tabRenameInProgress` reference and SU-C keeps one editor reference per DISTINCT tree (record the mapping; do NOT commit two byte-identical refs).
**Output**: `Tests/OuroWorkbenchAppViewsTests/InlineRenameEditorStateSetTests.swift` with the failing state-set tests (no references yet).
**Acceptance**: Tests exist and FAIL (no references yet, red).

#### ⬜ SU-C.b: record + verify references (green) + the no-op boundary negative control
**What**: Record after eyeballing provenance + no leak; COMPARE green. **MUTATION-verified negative control (the whitespace-no-op boundary, P2):** with a whitespace/empty draft, call `model.commitRename()` and assert (a) `WorkspaceRenameCommit.resolve` returned `.noop` so NO `nameOverride` was written (the workspace/tab `effectiveName` is unchanged via the model state), AND (b) a valid-prefill draft commit DOES write the override (the tree/state flips). Re-apply the exact guard mutation (e.g. break the `trimmed.isEmpty` guard so whitespace writes) → the negative-control test goes RED; revert → GREEN. Twice-run byte-identical; no `/Users/`.
**Output**: `__Snapshots__/C.*.txt` (the distinct editor trees) + the no-op-boundary test in a new `InlineRenameEditorStateSetTests.swift`.
**Acceptance**: References committed + COMPARE green; the whitespace-commit-writes-no-override boundary is asserted via model STATE (not just the tree) and is mutation-verified; no two refs byte-identical.

#### ⬜ SU-C.c: a11y-id audit + coverage + commit
**What**: a11y-id audit (D-U2-2): the editor carries `accessibilityLabel("Rename")`; two editor instances are disambiguated by their draft Text — confirm no negative control is defeated; add identifiers only if needed, else "none needed." Capture views-lib coverage % (`./U3-onboarding-recovery/views-coverage-after-SU-C.txt`). Commit `test(views): SU-C inline rename editor enumerated snapshots + no-op boundary negative control`. NO AI attribution.
**Acceptance**: Coverage % recorded; a11y-id decision recorded; commit landed; gates green.

---

### ⬜ SU-D: Recovery + Archived (`RecoverySheet`/`NeedsYouEntryRow`/`RecoverableEntryRow` + sidebar Archived) — full enumerated state-set

Independent. Provenance via `WorkbenchStore.save(state)` → fresh hermetic VM (AN-001) whose load derives `summary.recoveryPlans` through the PURE `RecoveryPlanner`; set `model.liveScreenSessionNames` (a settable `@Published`) for the `.reattach` (lossless) case. Recovery states are driven by each `ProcessEntry`'s latest `ProcessRun.status`: `.manualActionNeeded`→needs-you; `.needsRecovery`→auto-recoverable (resume/respawn); session-name ∈ `liveScreenSessionNames`→reattach. The trust-fix vs Start-fresh branch needs `entry.trust != .trusted` + `plan.blocker == .untrusted` (a `.manualActionNeeded` entry that is untrusted). The sidebar Archived section is an enumerated state of `WorkbenchSidebarView` (gate `!archivedSessionEntries.isEmpty`; an entry NOT in any workspace's `tabIds` is archived).

#### ⬜ SU-D0: spike (Q1 + Q2 — make-or-break, folds into SU-D, throwaway)
**What**: In a throwaway test, confirm (i) ViewInspector's `findAll` extracts the `ContentUnavailableView("Nothing to recover", …)` title/description `Text` so the "nothing" reference is meaningful (Q1); if NOT, decide the reversible fallback (assert the `Text("Recovery")` header + the ABSENCE of the "Needs you"/"Ready to recover" section headers) and record it. (ii) Confirm `RecoverySheet`'s `@Environment(\.dismiss)` + the sidebar `.task` do NOT crash/fire under the synchronous `inspect()` path (Q2; strong U2 precedent — `BossProposalCardList`/`WorkbenchSidebarView` both have `.task`).
**Output**: `./U3-onboarding-recovery/recovery-extraction-spike.md` (the verdict + the chosen "nothing"-state assertion strategy); throwaway test deleted.
**Acceptance**: A documented GO with the "nothing"-state strategy; the system-view extraction behavior is known; STOP-and-surface only if a node genuinely needs `ViewHosting` (an out-of-U3 source touch).

#### ⬜ SU-D.a: D state-set tests — FIRST (red)
**What**: Write FAILING `assertViewSnapshot` tests for the COMPLETE D state-set on `RecoverySheet` (each provenance-built via `WorkbenchStore.save` + `ProcessRun`s + `liveScreenSessionNames`), per the SU-D0 strategy:
- `D.nothing` — no actionable plans (`recoveryDigest.shouldShow == false`) → the "Nothing to recover" empty state.
- `D.needsYouOnly` — one `.manualActionNeeded` entry, zero auto-recoverable → "Needs you" section, NO "Ready to recover", NO Recover-All.
- `D.autoOne` — exactly one `.autoResume`/`.respawn` entry → "Ready to recover" with one row, NO Recover-All (gate `count > 1`).
- `D.autoMany` — ≥2 auto-recoverable entries → Recover-All button SHOWN.
- `D.both` — needs-you AND auto-recoverable → both sections.
- BOUNDARY `D.trustFix` vs the Start-fresh path: a `.manualActionNeeded` entry that is UNTRUSTED (`plan.blocker == .untrusted`) → "Trust & resume"; a `.manualActionNeeded` entry that is trusted/non-untrusted-blocker → "Start fresh". (May be folded into `D.needsYouOnly`/`D.both` fixtures using distinct entries — record the mapping.)
- BOUNDARY `D.losslessReattach`: an entry whose session name ∈ `liveScreenSessionNames` → the "Reconnect — no loss" pill + green link glyph + "Reconnect" button title; contrast a non-reattach auto-recoverable (no pill, orange glyph, "Resume"/"Respawn").
- Sidebar Archived: `D.sidebarArchived` — `WorkbenchSidebarView` with an archived entry (not in any workspace's `tabIds`) → the `Section("Archived")` renders (gate satisfied); contrast the empty-archived sidebar (no section). (This may reuse the SU3 sidebar fixture pattern; clock-free per C1.)
- Use DISTINCT `entry.name`s in "many"/"both" fixtures (Q6 a11y).
**Output**: `Tests/OuroWorkbenchAppViewsTests/RecoverySurfaceStateSetTests.swift` with the failing state-set tests (no references yet).
**Acceptance**: Tests exist and FAIL (red).

#### ⬜ SU-D.b: record + verify references (green) + mutation-verified negative controls
**What**: Record after eyeballing provenance (the planner emitted the intended plan mix — assert the digest buckets at the call site BEFORE the snapshot) + no leak (canonical fixture `executable`/`cwd`; the `.help("Recovery detail…")` tooltips are dropped by AN-004). COMPARE green. **MUTATION-verified negative controls (P2):** (1) flip a fixture `ProcessRun.status` `.needsRecovery`↔`.manualActionNeeded` → the row moves between "Ready to recover" and "Needs you" (tree flips); (2) add/remove the entry's session name from `liveScreenSessionNames` → the lossless pill appears/disappears; (3) flip `entry.trust` to `.trusted` → "Trust & resume" becomes "Start fresh". Prove each load-bearing by re-applying the exact mutation (RED) then reverting (GREEN). Twice-run byte-identical; no `/Users/`.
**Output**: `__Snapshots__/D.*.txt` in a new `RecoverySurfaceStateSetTests.swift` (+ the sidebar-archived state, which may live in `SidebarSurfaceStateSetTests` or the new file — record where).
**Acceptance**: All D references committed + COMPARE green; ≥1 (here several) mutation-verified negative controls flip; no two refs byte-identical; the digest-bucket provenance asserted per fixture.

#### ⬜ SU-D.c: a11y-id audit + coverage + commit
**What**: a11y-id audit (Q6/D-U2-2): recovery rows carry NO `accessibilityLabel` → confirm distinct `entry.name`/reason/`launchCommand` Text nodes disambiguate repeated rows so no negative control is defeated; add a minimal identifier ONLY if two rows serialize byte-identically, else "none needed." Capture views-lib coverage % (`./U3-onboarding-recovery/views-coverage-after-SU-D.txt`). Commit `test(views): SU-D recovery + archived enumerated snapshots + mutation-verified negative controls`. NO AI attribution.
**Acceptance**: Coverage % recorded; a11y-id decision recorded; commit landed; gates green.

---

### ⬜ SU-E1: Onboarding repair-step row (`OnboardingRepairStepRow`) — actor variants

Independent leaf. `OnboardingRepairStepRow(step: OnboardingRepairStep, model:)` — `step` is a Core struct constructible directly (its own input, a legitimate `View` seam, like U1's `SidebarWorkspaceEmptyRow`); the row reads `model` only for button-gate state, so build a hermetic VM (AN-001). The actor variants come from `step.actor` (`OnboardingRepairActor`: agentRunnable→"Workbench"/blue; humanRequired→"Needs you"/orange; humanChoice→"Choose"/purple) + the `step.id`-driven button variant (check-*→"Checking…"+Run/spinner; isProviderSetup→"Connect"; workbench-mcp→"Register"; repair-*-provider→"Try again"; else→"Fix").

#### ⬜ SU-E1.a: actor-variant tests — FIRST (red)
**What**: Write FAILING `assertViewSnapshot` tests, one per actor/id variant, each constructing a fixed `OnboardingRepairStep`:
- `E1.agentRunnable` — `OnboardingRepairStep(actor: .agentRunnable, id: "ensure-daemon", title:…, detail:…, command:[…])` → "Workbench" pill + "Fix"/`wand.and.stars`.
- `E1.humanRequired_providerSetup` — `id: "request-provider-config"` (`isProviderSetup`) → "Needs you" pill + "Connect"/`link`.
- `E1.humanChoice` — `id: "hatch", actor: .humanChoice` → "Choose" pill + button.
- `E1.checkInProgress` — `id: "check-outward"` with `command: []` (no commandLine) → "Checking…" pill + spinner (ProgressView; assert via the absence of a button / a stable node, since a spinner has no text).
- `E1.checkPending` — `id: "check-outward"` with a non-empty `command` → "Checking…" pill + "Run"/`play.fill`.
- Cover all three `OnboardingRepairActor` cases + the key `id`-driven button branches; MINIMAL non-redundant set (P4e).
**Output**: `Tests/OuroWorkbenchAppViewsTests/OnboardingRepairStepRowTests.swift` with the failing actor-variant tests (no references yet).
**Acceptance**: Tests exist and FAIL (red).

#### ⬜ SU-E1.b: record + verify references (green) + mutation-verified negative control
**What**: Record after eyeballing (pure Core copy → deterministic; no agent name/path). COMPARE green. **MUTATION-verified negative control (P2):** flip `step.actor` (`.agentRunnable`→`.humanRequired`) → the StatusPill label/color flips ("Workbench"→"Needs you"); flip `step.id` across a button-branch boundary (e.g. `check-` ↔ a `commandLine` step) → the button flips. Re-apply the exact `actorLabel`/`color` switch mutation (RED) then revert (GREEN). Twice-run byte-identical; no `/Users/`.
**Output**: `__Snapshots__/E1.*.txt` in a new `OnboardingRepairStepRowTests.swift`.
**Acceptance**: References committed + COMPARE green; each actor variant distinct; the actor-flip negative control mutation-verified; no two refs byte-identical.

#### ⬜ SU-E1.c: a11y-id audit + coverage + commit
**What**: a11y-id audit (the rows have no `accessibilityLabel`; distinct `step.title`/`detail` Text disambiguate) — "none needed" unless a collision defeats a control. Capture coverage % (`views-coverage-after-SU-E1.txt`). Commit `test(views): SU-E1 onboarding repair-step row actor variants + negative control`. NO AI attribution.
**Acceptance**: Coverage % recorded; a11y-id decision recorded; commit landed; gates green.

---

### ⬜ SU-E2: First-run bootstrap (`FirstRunBootstrapView` + `FirstRunMode`) — mode variants

Independent. `FirstRunBootstrapView` reads `model.firstRunPresentation` (`@Published`). Provenance (Q4 default): build the value via the PURE `FirstRunBootstrapDrive.presentIdle()` / `.present(result: BootstrapResult(phase:…), activeStep:)` from a controlled `BootstrapPhase`, then assign to `model.firstRunPresentation` — NOT the live async `runFirstRunBootstrap()` (which spawns real effects). `FirstRunMode(phase:)`: `.awaitingHandoff`→bootstrapping; `.parkedAwaitingProviderConfig`→parked; `.failedStep`/`.failedInvalidAgent`→needsAttention; `.handedOff`→agentDriven.

#### ⬜ SU-E2.a: mode-variant tests — FIRST (red)
**What**: Write FAILING `assertViewSnapshot` tests for the COMPLETE first-run state-set (each via the pure drive → assigned `@Published`):
- `E2.bootstrapping` — phase `.awaitingHandoff` → mode pill "starting"/blue + `FirstRunStepRow`s (per `presentation.rows` step states active/done/pending).
- `E2.parked` — phase `.parkedAwaitingProviderConfig` → "needs you"/orange + "Connect a provider" button.
- `E2.needsAttention` — phase `.failedStep` (+ `attentionReason: .failedStep`) → "needs attention"/red + the reason line + "Try again"; and the `.invalidBoss` reason variant → "Choose a boss" (record whether one or two refs).
- `E2.agentDriven` — phase `.handedOff` → "agent driving"/green + the `FirstRunNarrationRow` (set `model.firstRunAgentDrivenNarration` = the static Core copy).
- `E2.nil` — `firstRunPresentation == nil` → the view renders nothing (empty tree). (Note: `FirstRunBootstrapView` is normally embedded; snapshot it standalone for the nil/mode matrix — a legitimate leaf, like U1.)
**Output**: `Tests/OuroWorkbenchAppViewsTests/FirstRunBootstrapViewTests.swift` with the failing mode-variant tests (no references yet).
**Acceptance**: Tests exist and FAIL (red).

#### ⬜ SU-E2.b: record + verify references (green) + mutation-verified negative control
**What**: Record after eyeballing (pure Core copy → deterministic; the only var is the agent name in some attention copy — use a fixed fixture name; no path). COMPARE green. **MUTATION-verified negative control (P2):** change the input `BootstrapPhase` (e.g. `.parkedAwaitingProviderConfig`→`.failedStep`) → the mode pill/icon + the gate-button flip; re-apply the exact `FirstRunMode(phase:)` mapping mutation (RED) then revert (GREEN). Twice-run byte-identical; no `/Users/`.
**Output**: `__Snapshots__/E2.*.txt` in a new `FirstRunBootstrapViewTests.swift`.
**Acceptance**: References committed + COMPARE green; each mode distinct; the phase→mode mapping negative control mutation-verified; no two refs byte-identical.

#### ⬜ SU-E2.c: a11y-id audit + coverage + commit
**What**: a11y-id audit ("none needed" expected — distinct headlines/step lines). Capture coverage % (`views-coverage-after-SU-E2.txt`). Commit `test(views): SU-E2 first-run bootstrap mode variants + negative control`. NO AI attribution.
**Acceptance**: Coverage % recorded; a11y-id decision recorded; commit landed; gates green.

---

### ⬜ SU-E3: Boss-choice (`OnboardingBossChoiceView`/`OnboardingBossChoiceRow`) — choice states

Independent (after the SU-E0 injection spike). Provenance (Q3 default): inject `model.ouroAgents = [OuroAgentRecord(...)]` directly with FIXED records (the same `@Published` the live scanner writes; no temp-path leak — boss-choice does NOT render `bundlePath`/`configPath`). AN-001 temp `agentBundlesURL` STILL injected (so a stray `refreshOuroAgents()` scans empty). `onboardingBossChoices` derives names from `ouroAgents` + `state.boss.agentName`; `isSelected` ← `state.boss.agentName` match; `isUsable` ← `status == .ready` + valid bundle name.

#### ⬜ SU-E0: boss-choice provenance spike (Q3 + Q4 + Q2 — make-or-break, folds into SU-E3, throwaway)
**What**: Confirm that setting `model.ouroAgents = [fixed records]` (+ a fixed `state.boss.agentName`) produces the intended `onboardingBossChoices` (names/status/isSelected/isUsable) WITHOUT a `refreshOuroAgents()` scan of the real home (Q3); confirm the readiness/first-run producers (Q4) likewise map injected inputs deterministically (validate the chosen producer call for SU-E2/SU-E4); confirm `OnboardingBossChoiceView`/`OnboardingReadinessView` `.onAppear`/no-`.task` side-effects don't fire under `inspect()` (Q2). Record the chosen seam; STOP-and-surface if direct injection can't set a rendered field (fall back to fixture-bundle scanning, recorded).
**Output**: `./U3-onboarding-recovery/onboarding-provenance-spike.md`; throwaway test deleted.
**Acceptance**: A documented GO with the boss-choice + readiness + first-run injection seams; no live home scan; no `.onAppear` effect fires.

#### ⬜ SU-E3.a: boss-choice state-set tests — FIRST (red)
**What**: Write FAILING `assertViewSnapshot` tests for the COMPLETE boss-choice state-set:
- `E3.none` — empty `ouroAgents` + empty boss name → "No local agents found" + Create/Clone buttons. (Note: a non-empty `state.boss.agentName` always yields ≥1 choice; for a true "none" set `state.boss.agentName = ""` — verify this is the real empty seam.)
- `E3.one` — one fixed `OuroAgentRecord` → one `OnboardingBossChoiceRow`.
- `E3.many` — ≥2 fixed records (distinct names) → multiple rows.
- `E3.selected` — `state.boss.agentName` matches one record → that row shows the "selected" pill + filled radio.
- `E3.unusable` — a record with `status != .ready` (e.g. `.disabled`) → the row renders but `isUsable == false` (disabled); the status pill reads "turned off"/"needs setup".
- MINIMAL non-redundant set (fold selected+usable into the "many" fixture where it doesn't defeat a control).
**Output**: `Tests/OuroWorkbenchAppViewsTests/OnboardingBossChoiceViewTests.swift` with the failing choice-state tests (no references yet).
**Acceptance**: Tests exist and FAIL (red).

#### ⬜ SU-E3.b: record + verify references (green) + mutation-verified negative control
**What**: Record after eyeballing (FIXED agent names, pure Core status copy → deterministic; NO `bundlePath`/`configPath` rendered → no path leak; AN-001 confirms no home scan). COMPARE green. **MUTATION-verified negative control (P2):** flip a record's `status` `.ready`↔`.disabled` → `isUsable`/the status pill flips (and `.disabled(!isUsable)` changes the tree's disabled trait); change `state.boss.agentName` → the "selected" pill moves. Re-apply the exact `isUsable`/`statusLabel` mutation (RED) then revert (GREEN). Twice-run byte-identical; no `/Users/`, no real agent names.
**Output**: `__Snapshots__/E3.*.txt` in a new `OnboardingBossChoiceViewTests.swift`.
**Acceptance**: References committed + COMPARE green; each choice state distinct; the status/usability negative control mutation-verified; no machine agent-name leak.

#### ⬜ SU-E3.c: a11y-id audit + coverage + commit
**What**: a11y-id audit: rows use `.accessibilityElement(children: .combine)` + `.isSelected` trait; distinct `choice.name` disambiguates → "none needed" unless a collision defeats a control. Capture coverage % (`views-coverage-after-SU-E3.txt`). Commit `test(views): SU-E3 onboarding boss-choice enumerated snapshots + negative control`. NO AI attribution.
**Acceptance**: Coverage % recorded; a11y-id decision recorded; commit landed; gates green.

---

### ⬜ SU-E4: Readiness (`OnboardingReadinessView`) — readiness states (DEPENDS ON SU-E1 + SU-E2)

Depends on SU-E1 (repair-step row) + SU-E2 (first-run view), which `OnboardingReadinessView` embeds in its not-ready branch. Provenance (Q4 default): build `model.onboardingReadiness` via the PURE `WorkbenchOnboardingAdvisor().readiness(boss:agents:mcpRegistration:providerChecks:daemonLiveness:)` with controlled inputs, then assign to the `@Published`. The view also embeds `OnboardingAgentProviderSummary` (reads `model.ouroAgent(named:)` → provider·model label; inject the matching fixed `OuroAgentRecord`). Hermetic VM (AN-001).

#### ⬜ SU-E4.a: readiness state-set tests — FIRST (red)
**What**: Write FAILING `assertViewSnapshot` tests for the COMPLETE readiness state-set (each via the pure advisor → assigned `@Published`):
- `E4.nil` — `onboardingReadiness == nil` → the header texts only (the readiness body is inside `if let readiness`).
- `E4.notReady` — `state: .needsAgent`/`.needsCredentials`/`.needsRepair` (`isReady == false`) → embeds `FirstRunBootstrapView` + the `OnboardingStatusRow(headline, detail)` + the repair steps.
- `E4.ready` — `state: .ready`, empty `repairSteps` → checkmark + "<boss> is ready" + the scan-intro, NO "Optional checks".
- `E4.readyOptional` — `state: .ready` with NON-empty `repairSteps` → the ready surface + the "Optional checks" section with `OnboardingRepairStepRow`s.
- `E4.inProgress` — a `repairStep` with id prefix `check-` (the "Checking…" actorLabel + spinner) AND/OR an `onboardingProviderChecks[lane] = .running` → the in-progress check surface + the "first connection check…can take up to a minute" caption.
- Use a FIXED boss name + fixed `OuroAgentRecord` (the only var); MINIMAL non-redundant set.
**Output**: `Tests/OuroWorkbenchAppViewsTests/OnboardingReadinessViewTests.swift` with the failing readiness-state tests (no references yet).
**Acceptance**: Tests exist and FAIL (red).

#### ⬜ SU-E4.b: record + verify references (green) + mutation-verified negative control
**What**: Record after eyeballing (pure advisor copy + fixed name → deterministic; provider·model label from the fixed record; no path/clock). COMPARE green. **MUTATION-verified negative control (P2):** change the advisor inputs so `OnboardingReadinessState` flips `.ready`↔`.needsCredentials` → the ready surface ↔ the not-ready (bootstrap+repair) surface flips; add/remove a `repairStep` → the "Optional checks" section appears/disappears. Re-apply the exact `isReady`/state mutation (RED) then revert (GREEN). Twice-run byte-identical; no `/Users/`, no real agent name.
**Output**: `__Snapshots__/E4.*.txt` in a new `OnboardingReadinessViewTests.swift`.
**Acceptance**: References committed + COMPARE green; each readiness state distinct; the readiness-state negative control mutation-verified.

#### ⬜ SU-E4.c: a11y-id audit + coverage + commit + UNIT CLOSE
**What**: a11y-id audit (distinct headlines/step titles → "none needed" expected). Capture FINAL views-lib coverage % (`views-coverage-after-SU-E4.txt`). Commit `test(views): SU-E4 onboarding readiness enumerated snapshots + negative control`. Update the CAMPAIGN journal + backlog: append the U3-COMPLETE iteration entry (the running views-lib coverage progression; any new fork/observation; no AN-00x newly fixed unless a spike surfaces one). NO AI attribution.
**Acceptance**: Coverage % recorded; a11y-id decision recorded; commit landed; gates green; campaign journal updated.

---

## Execution

- **TDD strictly enforced** (the snapshot variant): tests → red → record (only after eyeballing provenance P2 + no leak P3) → green → refactor. Negative controls MUTATION-verified.
- One commit per sub-unit (the a/b/c phases co-commit at the sub-unit boundary; never batch across sub-units). No PR; the campaign merges the branch.
- Run the full strict suite + `--uisurfacetest` + `Scripts/check-coverage.sh` before marking each sub-unit done. Confirm `COVERAGE_DIRS` + allowlist UNCHANGED and ~268 grep-guards green each time.
- **All artifacts** → `./U3-onboarding-recovery/` (spikes, per-surface coverage snapshots, gate logs, review records).
- **Fixes/blockers**: spawn a sub-agent immediately — don't ask, just do it (operator asleep). Record the decision in this doc + the campaign journal; commit right away.
- **Reviewer discipline (anneal §4):** never run two build-lock-holding agents in one checkout — worktree-isolate, or make all-but-one reviewer static-only, or stagger. The fresh review gate (P5) runs before READY and pre-merge.
- **AN-001 in EVERY VM fixture**: temp `agentBundlesURL` into BOTH `BossWorkbenchMCPRegistrar(agentBundlesURL:)` AND `OuroAgentInventory(agentBundlesURL:)`.
- **`SerpentGuide.ouro/` stays unstaged. NO AI attribution anywhere.**

## Context / References

- Campaign journal + rubric (P1–P7 + the upgraded P2 mutation measure) + surface state-sets + backlog (AN-001…AN-005): `../2026-06-24-anneal-visual-testing.md`.
- anneal SKILL (loop, guardrails, P5 gate, MUTATION-based P2, build-lock lesson, autonomous driving): `~/.claude/skills/anneal/SKILL.md`.
- The proven U2 patterns (the exact test shape to mirror): `Tests/OuroWorkbenchAppViewsTests/{SidebarSurfaceStateSetTests,TabStripSurfaceStateSetTests,BossProposalCardStateSetTests,TerminalAgentRowRunningLeafTests}.swift`; harness: `…/{ViewSnapshotHost,ViewTreeSerializer,ViewSnapshotNode,ViewSnapshotStore,AssertViewSnapshot}.swift`.
- **Surface C** (re-located @ 976610d): `InlineRenameEditor` `WorkbenchViewsAndModel.swift:3169` (internal, `@ObservedObject var model`); body `TextField("Name", text: $model.inlineRename.draft)` `:3174` + `Text("Press Enter to rename, Escape to cancel.")` `:3178` + `.accessibilityLabel("Rename")` `:3183`; call sites — workspace `:3075` (`WorkspaceSidebarRow`, gate `inlineRename.isEditing(.workspace(row.id))`), tab `:3301` (`WorkspaceTabStrip.tabButton`, gate `.isEditing(.tab(tab.id))`). State: `model.inlineRename` (`InlineRenameState`, `@Published`, VM `:10491`; type in `Sources/OuroWorkbenchCore/InlineRenameState.swift`). Commit: `model.commitRename()` `:11538` → `WorkspaceRenameCommit.resolve(input:current:)` (Core) → `.noop` on empty/whitespace/unchanged (the no-override boundary). DETERMINISTIC (no clock/path).
- **Surface D** (re-located): `RecoverySheet` `:821` (internal, `@ObservedObject`, `@Environment(\.dismiss)`), `NeedsYouEntryRow` `:941` (private, `var entry: ProcessEntry`), `RecoverableEntryRow` `:1018` (private), sidebar Archived section `WorkbenchSidebarView` `:3013` (gate `!model.archivedSessionEntries.isEmpty`, `Section("Archived")`, uses `TerminalAgentRow` built WITHOUT `runningSince:` → clock-free, consistent with C1). Recover-All gate `:840` `model.autoRecoverableEntries.count > 1`. Lossless pill `:1041` `Text("Reconnect — no loss")` (gate `isReattach = recoveryPlan?.action == .reattach`). Trust-fix vs Start-fresh `:974` (gate `recoveryTrustFixAvailable` = `.manualActionNeeded` + `entry.trust != .trusted` + `plan.blocker == .untrusted`). Seam: `recoveryDigest = RecoveryDigest(plans: summary.recoveryPlans)` (`:14548`); `summary = summarizer.summarize(state, liveSessionNames: liveScreenSessionNames)` (`:11740`); `liveScreenSessionNames` is `@Published` (`:10808`, default `[]` → settable). `RecoveryPlanner.planRecovery(for state:liveSessionNames:)` is PURE (`Sources/OuroWorkbenchCore/RecoveryPlanner.swift:69`): `.manualActionNeeded` ← `ProcessRun.status == .manualActionNeeded`; `.autoResume`/`.respawn` ← `.needsRecovery`; `.reattach` ← entry session name ∈ `liveSessionNames`; `.noAction` ← archived / no run. `RecoveryDigest` (Core `RecoveryDigest.swift:20`) buckets these. `ProcessStatus` cases (`WorkspaceModels.swift:28`): `.running/.exited/.needsRecovery/.manualActionNeeded`.
- **Surface E** (re-located): router `WorkbenchOnboardingSheet` `:6310` / `OnboardingPageContent` `:6552` (campaign's "OnboardingPage 6417" is STALE). `OnboardingBossChoiceView` `:6670` (private, renders `model.onboardingBossChoices`, empty→"No local agents found"); `OnboardingBossChoiceRow` `:6727` (radio + `choice.name` + "selected" pill + `statusLabel` pill + `detail`; `.disabled(!choice.isUsable)`; `.accessibilityElement(children: .combine)` + `.accessibilityAddTraits(.isSelected)`). `OnboardingReadinessView` `:6955` (private, renders `model.onboardingReadiness`; `isReady`→checkmark + "X is ready" + optional "Optional checks"; else→`FirstRunBootstrapView` + status row + repair steps; `.onAppear { startFirstRunBootstrapIfNeeded() }` `:7035`). `FirstRunBootstrapView` `:6800` (private, switches `presentation.mode`: `.agentDriven`→narration; else `FirstRunStepRow`s + provider-gate button + retry/choose-boss button). `OnboardingRepairStepRow` `:7117` (private, `StatusPill(actorLabel)` + `step.title`/`step.detail` + variant button; actorLabel "Workbench"/"Needs you"/"Choose"/"Checking…"). Seams: `onboardingBossChoices` `:12041` ← `bossAgentChoices` `:12679` ← `ouroAgents` (`@Published`, `:10762`) ← `OuroAgentInventory.scan()` of `~/AgentBundles` (`OuroAgentInventory.swift:115`, injectable `agentBundlesURL`). `onboardingReadiness` `@Published` `:10888` ← pure `WorkbenchOnboardingAdvisor.readiness(...)` (`Onboarding.swift:189`). `firstRunPresentation` `@Published` `:10624` ← pure `FirstRunBootstrapDrive.presentIdle()/.present(result:)` (`FirstRunBootstrapDrive.swift:324/338`). `FirstRunMode` (Core enum, `FirstRunBootstrapDrive.swift:123`): bootstrapping/parkedAwaitingProvider/needsAttention/agentDriven ← `init(phase: BootstrapPhase)`. `OnboardingReadiness`/`OnboardingReadinessState`/`OnboardingRepairStep`/`OnboardingRepairActor` (Core, `Onboarding.swift:78/9/17/3`). NO `Date()`/path/version rendered in any E surface (the `:8145`/`:8156` path-rendering view is a DIFFERENT inventory pane, out of scope).
- Coverage gate (UNCHANGED this unit): `Scripts/check-coverage.sh` (`COVERAGE_DIRS` = Core + ShellAdapter; allowlist `scripts/coverage-allowlist.txt`). `--uisurfacetest`: `Sources/OuroWorkbenchApp/{main.swift,UISurfaceTest.swift}`. ViewInspector test-only dep (exact `0.10.3`, `exclude: ["__Snapshots__"]`): `Package.swift`.
- Baselines @ 976610d: views-lib coverage 7.70% region / 6.94% line (post-U2); ~268 grep-guard sites; 16 AppViews test files; 27 committed `__Snapshots__`.

## Notes

- **Determinism landmines audited in C/D/E (P3) + how each fixture pins them:**
  - **C (inline editor):** none. Renders only `Text("Press Enter…")` + the bound `inlineRename.draft` (a fixed fixture string) + `.accessibilityLabel("Rename")`. No clock/path/name. Pinned by a fixed draft value.
  - **D (recovery):** (1) `launchCommand(for: entry)` (`:997`/`:1082`) → `WorkbenchCommandPlanner(paths:).launchPlan(entry).displayCommand` = shell-quoted `[executable]+args` — pinnable via a canonical fixture entry (fixed `executable`, no machine args); does NOT include the working directory. (2) `recoveryReason`/`recoveryReasonSentence` → planner `plan.reason` (e.g. "respawn <name> from persisted workbench context") — deterministic for a fixed entry name + action; the dangerous `.help("Recovery detail: …")` tooltips (`:962`/`:1061`) are already DROPPED by the host's AN-004 `isHelpTooltip`. (3) `entry.name`/`entry.lastSummary` are fixture-controlled. No `Date()`/elapsed in any recovery view. Pin: canonical fixed-fixture entries (fixed name/executable/cwd), DISTINCT names in "many".
  - **E (onboarding):** the ONLY machine-specific input is the AGENT NAMES + provider·model labels in boss-choice/readiness, sourced from `OuroAgentInventory.scan()` of `~/AgentBundles`. Pin: AN-001 temp `agentBundlesURL` injection (so a stray `refreshOuroAgents()` scans an empty temp dir, not the real home) + FIXED `OuroAgentRecord` fixtures (Q3 default: direct `ouroAgents` injection). All readiness/first-run/repair-step COPY is pure Core constants (deterministic). No `Date()`/path/version in any E surface (the path-rendering inventory pane `:8145`/`:8156` is out of scope). `.onAppear`/`.task` side-effects do NOT fire under the synchronous `inspect()` path (U2 precedent; confirm per spike).
- **Provenance-impossibility scan (the C1 lesson) — result: NONE found in C/D/E.** D's `.reattach` (the C1-risk: "needs a live screen session") is buildable because `model.liveScreenSessionNames` is a settable `@Published` (the same property the live `screen` poller writes) — set it to the entry's session name and the planner emits `.reattach`. E's every state is buildable through the pure Core producers (the E sub-agent found no impossibility). C's "no-op whitespace commit" is buildable via `inlineRename.draft = "   "` + `commitRename()`. **No state needs a standalone-leaf carve-out or an unreachable-observation record this unit** (contrast U2's C1, where the sidebar elapsed pill was genuinely unreachable and moved to SU3r). If a spike surfaces an unexpected unreachable state, it moves to a leaf or an observation — never fabricated.
- **Genuine forks worth surfacing** (resolved with reversible defaults — Q1–Q6): the system-view (`ContentUnavailableView`) extraction (Q1), the boss-choice injection seam (Q3), the readiness/first-run producer-vs-direct seam (Q4). None blocks; each has a recorded default.
- The AN-001 SOURCE fix (route the detached cleanup + the inventory default through injected `paths`) stays OPEN; U3 mitigates in-fixture (the standard).
- Grep-guard baseline (P7): ~268 sites; U3 does NOT retire any (tracks to U4).

## Progress Log
- 2026-06-25 09:22 Created from the campaign journal (U3 intake). Surfaces C/D/E mapped first-hand + via 3 parallel Explore fan-outs; all campaign §Surfaces line refs RE-LOCATED + validated @ 976610d (stale by ~100–120 lines post-extraction). Every provenance seam traced to its Core type (`RecoveryPlanner`/`RecoveryDigest`/`WorkbenchOnboardingAdvisor`/`FirstRunBootstrapDrive`/`OnboardingRepairActor`); the `.reattach` C1-risk resolved (`liveScreenSessionNames` is a settable `@Published` → NO provenance gap); determinism landmines enumerated per surface. Status: drafting.
- 2026-06-25 09:25 Committed (`43eddd9`). Autonomous mode (operator asleep): per the campaign's U1/U2 precedent the fresh unbiased sub-agent review gate substitutes for human signoff; planning marked approved → proceeding to Phase 2 (convert to the doing doc; review gate runs before READY_FOR_EXECUTION). Forks Q1–Q6 resolved with recorded reversible defaults.
