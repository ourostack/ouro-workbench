# ANNEAL Campaign — Agent-Friendly Visual-Testing System

**Skill:** `~/.claude/skills/anneal/SKILL.md` · **Started:** 2026-06-24 (overnight, autonomous) · **Driver:** main loop + heartbeat
**Status:** Phase 0 (build the system) — in progress. NOT yet measuring/annealing existing snapshots (none exist until Phase 0 lands).
**Resumability:** this doc is the journal. Update every iteration + commit. A reboot must lose nothing.

## Scope

The App-target visual surfaces of Ouro Workbench + the test infrastructure that proves them. Drive to a **defect-free fixed point** (energy 0) per the rubric below. Start narrow (the ④-relevant + workspace surfaces), widen deliberately.

## Definition of "perfect" (the instantiated rubric — the one human-gated knob)

Energy = count of violations. Annealed = energy 0 + clean re-measure. Operator-confirmed principles folded in: **honest verified allowlist > contorting a test to hit 100% (quality, not a gamed metric); AX/structural text snapshots are the GATE; pixel renders are optional NON-gating artifacts (avoid CI font/AA flakiness).**

| ID | Criterion | Exact pass/fail check |
|---|---|---|
| P1 | Every `View` in the extracted views library is exercised (snapshot or structural test), or allowlisted with a *verified* GUI/lifecycle/PTY justification. | `Scripts/check-coverage.sh` (extended `COVERAGE_DIRS`) PASS; allowlist exact counts; `@main`/`App`/`AppDelegate`/`TerminalPane` live outside the gated lib. |
| P2 | Each invariant has a negative control (breaking the fixture flips the asserted tree); NO fixture asserts a state the real seam can't produce (the ②b law). | ≥1 negative-control per surface flips the diff; every fixture built via real model/queue (`AgentProposalQueue.enqueue`, `WorkbenchStore.save`→VM), never hand-assembled output. |
| P3 | Every AX snapshot byte-identical across repeated runs + CI. | `swift test` twice → `git diff --exit-code` on `__Snapshots__`; clock/locale/tz/UUID injected; `.help`/tooltip excluded; no `Date()`/`.now`/`UUID()` in serialized tree. |
| P4a | Snapshot is structured text, agent-legible (role/label/value/id/children, indented). | parses as the indented tree grammar; no pixels in the gate. |
| P4b | Minimal-noise — only load-bearing AX structure (no geometry/color/font/tooltip/address). | serializer whitelist; diff shows only role/label/value/id/children. |
| P4c | Each named surface has its COMPLETE enumerated state-set (empty/one/many/filtered/error/boundary). | one committed snapshot per enumerated state (checklist per surface, below). |
| P4d | Committed + CI-diffed + artifact-on-failure. | reference files in repo; CI diffs; failing tree/PNG uploaded. |
| P4e | Non-redundant — no two snapshots assert the same tree. | no two `__Snapshots__` files byte-identical. |
| P5 | ≥2 independent adversarial reviewers, zero surviving CRITICAL/HIGH. | work-suite gate; reviewer checks fixture provenance (P2) + determinism (P3). |
| P6 | Full suite green in CI, zero flakes, strict flags clean. | `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` green; coverage + snapshot jobs green. |
| P7 | Brittle source-grep guards retired as their surface gains real structural coverage. | `grep -rc 'source.contains(\|sourceSlice('` strictly decreases per converted surface; non-view wiring guards (MCP/process) may remain, explicitly listed. |

## Baseline energy (measured 2026-06-24)

- Core/ShellAdapter: 100% gated (allowlist = 2). **App target: NOT gated** (executableTarget can't `@testable import`).
- `OuroWorkbenchApp.swift`: **21,326 lines, 121 `View` structs**, **0/121 with any structural test**. Only `--uisurfacetest` `fittingSize>0` smoke + **296 grep-guard sites** (130 `source.contains` + 166 `sourceSlice`, across 48 test files; 253 in `*WiringTests`).
- Determinism debt to close: 0 `accessibilityIdentifier`, 39 `Date()`/`.now`, `ElapsedTimePill` `TimelineView(.periodic(from:.now,by:30))` @ `OuroWorkbenchApp.swift:3883`, 4 `UUID()` sites.

## Surfaces + complete P4 state-sets (the snapshot checklist)

- **A. Sidebar rows** (`WorkbenchSidebarView` 3033, `WorkspaceSidebarRow` 3173, `SidebarWorkspaceEmptyRow` 3295): empty / one / many (pinned-first) / active vs inactive / empty-workspace marker / summary idle vs needs-you / rename-in-progress · boundary: pinned+active; custom-override (enables Remove-Custom-Name).
- **B. Tab-strip** (`WorkspaceTabStrip` 3313): no-active-ws (nil) / empty-ws ("— no tabs yet") / filtered-to-empty ("No sessions match…"+Clear) / one / many / selected vs not / tab-rename · boundary: filter-empty vs genuinely-empty (two distinct states, FP4).
- **C. Inline editors** (`InlineRenameEditor` 3275): editing-workspace / editing-tab / empty-whitespace draft (no-op) / prefilled-valid · boundary: whitespace commit closes w/o writing override.
- **D. Archived + Recovery** (`RecoverySheet` 941, `NeedsYouEntryRow` 1061, `RecoverableEntryRow` 1138 + sidebar Archived): nothing / needs-you-only / auto:one (no Recover-All) / auto:many (Recover-All) / both · boundary: trust-fix vs Start-fresh; lossless-reattach pill vs not.
- **E. Onboarding** (`OnboardingPage` 6417; `OnboardingBossChoiceView` 6772, `OnboardingReadinessView` 7057, `FirstRunBootstrapView` 6902 `FirstRunMode`, `OnboardingRepairStepRow` 7219): boss-choice {none/one/many/selected/unusable}; readiness {nil/not-ready/ready/ready+optional/in-progress}; first-run {bootstrapping/parked/needsAttention/agentDriven/nil}; repair-step actor variants.
- **F. Bring-back proposal card (slice ④)** (`BossProposalCardList` 7420, `BossProposalCard` 7438, `BossProposalItemRow` 7483; model `AgentProposal.swift`, transport `AgentProposalQueue.swift`): list {none/one/many}; card {0 items/one/many; counter none/some/all}; itemRow {selected vs not; each of label/detail/command/cwd × editable/static/absent} — `editableFields` is the boundary driver.

## Decisions (reversible/auditable)

- **D-A1** Path A (library extraction) — the only way to coverage-gate views + retire grep guards. **Incremental, not big-bang** (scope discipline).
- **D-A2** AX-tree text snapshots = primary gate, **no new dependency** (NSHostingView + AppKit AX API; we own the serializer).
- **D-A3** **ViewInspector DEFERRED** (U5). It's a 3rd test-only dep vs the lean 2-dep posture. AX-snapshots + importable views retire most grep guards without it. If genuinely needed → **surface to operator** (the one supply-chain call), don't add unsupervised.
- **D-A4** Pixel renders = optional NON-gating PNG artifacts (operator: realistic + maintainable; avoid CI font/AA flakiness).
- **D-A5** Honest verified allowlist (`@main`/`App`/`AppDelegate`/`TerminalPane`) > test contortions. Quality, not a gamed number.
- **D-A6** `ScenarioVerifier`'s "25k renders" are a **mock canvas** (`ScenarioVerifier/main.swift:722,766`), NOT the real views — left as-is; the new harness renders the real `NSHostingView` (strict improvement). Do NOT delete `runMigratedWorkspaceSmoke()` provenance checks (real P2).

## PERT (Phase 0)

```
U0 ─► U1 ─► U2 ─► U4
          └► U3 ─┘
U0 ─► U5 (DEFERRED — ViewInspector dep; operator gate)
```
- **U0 — Views-library extraction (CRITICAL PATH).** New `OuroWorkbenchAppViews` library; move the 121 views + `WorkbenchViewModel`; thin executable keeps `main.swift`/`App`/`AppDelegate`/`TerminalPane`. Update `appSource()` to read the new lib dir (decouples the 296 grep guards from the old file path — do this EARLY). **Decompose into smallest safe increments; first PR minimal + proves build/test/harness end-to-end on ≥1 view.** No behavior change; strict flags green.
- **U1 — AX snapshot harness (no dep).** Deterministic NSHostingView AX walk + serializer + fixed clock/locale/tz/UUID + `__Snapshots__` + artifact-on-failure.
- **U2 — First snapshots: proposal card (④) + sidebar + tab-strip** (surfaces A/B/F), real fixtures, add `.accessibilityIdentifier`.
- **U3 — Recovery/archived + onboarding** (C/D/E). Parallel w/ U2 if non-overlapping.
- **U4 — Coverage extension to 100% on views lib** + honest allowlist (chokepoint; needs U2+U3 tests).
- **U5 — ViewInspector conversion (DEFERRED).** Retire grep guards; operator gate for the dep.

Chokepoints: U0, U4. Fan-out: U2/U3 (and U5 after U0).

## Iteration log

- 2026-06-24 — Baseline measured; rubric instantiated; campaign doc created; branch `feat/anneal-views-lib-extract` off main @ 8c2adce. Next: plan U0 (incremental views-lib extraction).
- 2026-06-25 00:2x — U0 planned (READY_FOR_EXECUTION): 7 units → ~9 serial PRs. Planner caught the infeasible exe-boundary (`TerminalPane` can't stay in exe → forbidden lib→exe edge) and corrected it (VM + 4 coupled types move INTO the lib, allowlisted); review gate caught the `sourceSlice` declaration-order CRITICAL (resolved via adjacency-preserving union concat). Safety valve not tripped.
- 2026-06-25 ~01:0x — **PR1 (Units 0-2) MERGED → #288 @ 24c5d26.** Importability seam live: first-ever `@testable import` of an App view (`DashboardRowLabel`); `appSource()` union-reader keeps all ~257 guards executing+passing; vacuity proven absent via reviewer negative-controls. No behavior change; coverage unchanged (lib not gated yet → U4). Energy unchanged (still building the system; nothing to anneal until snapshots exist).
- 2026-06-25 ~01:4x — Starting **Unit 3** (the VM + 4 coupled exe-types + ~12 support types move; the one unavoidably-larger mechanical PR; ≥2 adversarial reviewers) on `feat/anneal-u3-viewmodel-move` off main @ 24c5d26.
