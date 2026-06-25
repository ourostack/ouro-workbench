# U3 — Planning → Doing coverage checklist (Pass 5)

Systematic verification that the doing doc captures EVERYTHING from the planning sections. ✅ = has a doing unit; ❌ = MISSING (would need a unit). Built end-to-end from the planning doc.

## In Scope → doing unit

| Planning In-Scope item | Doing unit | Status |
|---|---|---|
| C inline editors: editing-workspace / editing-tab / empty-whitespace draft / prefilled-valid + whitespace-no-op boundary | SU-C.a (states) + SU-C.b (no-op boundary negative control) | ✅ |
| D recovery: nothing / needs-you-only / auto:one / auto:many (Recover-All) / both | SU-D.a (`D.nothing`/`D.needsYouOnly`/`D.autoOne`/`D.autoMany`/`D.both`) | ✅ |
| D boundary: trust-fix vs Start-fresh | SU-D.a (`D.trustFix`) + SU-D.b negative control (flip `entry.trust`) | ✅ |
| D boundary: lossless-reattach pill vs not | SU-D.a (`D.losslessReattach`) + SU-D.b negative control (`liveScreenSessionNames`) | ✅ |
| D sidebar Archived section | SU-D.a (`D.sidebarArchived`) | ✅ |
| E boss-choice {none/one/many/selected/unusable} | SU-E3.a (`E3.none/one/many/selected/unusable`) | ✅ |
| E readiness {nil/not-ready/ready/ready+optional/in-progress} | SU-E4.a (`E4.nil/notReady/ready/inProgress`) — **`ready+optional` RECLASSIFIED as unreachable (AN-006)**: the advisor reaches `.ready` only with EMPTY `repairSteps`, so the "Optional checks" branch is dead; recorded as an unreachable-observation, NOT fabricated (review-gate CRITICAL, verified first-hand). | ✅ (reclassified, not silently dropped) |
| E first-run {bootstrapping/parked/needsAttention/agentDriven/nil} | SU-E2.a (`E2.bootstrapping/parked/needsAttention/agentDriven/nil`) | ✅ |
| E repair-step actor variants {agentRunnable/humanRequired/humanChoice} | SU-E1.a (`E1.agentRunnable/humanRequired_providerSetup/humanChoice` + check variants) | ✅ |
| Per surface: provenance via real seam (P2) | each SU intro + each .a/.b (assert digest/state at call site) | ✅ |
| Per surface: ≥1 MUTATION-verified negative control (P2) | SU-C.b, SU-D.b, SU-E1.b, SU-E2.b, SU-E3.b, SU-E4.b | ✅ |
| Per surface: determinism P3 (fixed clock/locale/UTC; no machine path; AN-001) | each .b (twice-run + no-`/Users/` scan) + each SU intro (AN-001) | ✅ |
| AN-001 temp `agentBundlesURL` in BOTH registrar AND inventory in EVERY VM fixture | each SU intro + Execution + D-U3-2 | ✅ |
| Per-surface a11y-identifier audit (selective) | SU-C.c, SU-D.c, SU-E1.c, SU-E2.c, SU-E3.c, SU-E4.c | ✅ |
| Record running views-lib coverage % per surface | each .c (`views-coverage-after-SU-*.txt`) | ✅ |
| One commit per sub-unit; no AI attribution; SerpentGuide unstaged | Execution + each .c commit line | ✅ |
| Fresh unbiased sub-agent review gate before READY | Execution + Status note + Progress Log | ✅ (gate runs post-conversion, pre-READY) |

## Open Questions (forks) → resolution unit

| Fork | Reversible default | Doing unit that exercises/confirms it |
|---|---|---|
| Q1 `ContentUnavailableView` extraction | assert surrounding stable nodes if system view opaque | SU-D0 spike | ✅ |
| Q2 `@Environment(\.dismiss)` / `.onAppear`/`.task` no-fire | rely on U2 precedent; verify per surface | SU-D0 + SU-E0 spikes | ✅ |
| Q3 boss-choice: direct `ouroAgents` injection vs fixture bundles | direct `model.ouroAgents` injection | SU-E0 spike + SU-E3 | ✅ |
| Q4 readiness/first-run: pure producer vs direct `@Published` | build via pure Core producer → assign `@Published` | SU-E0 spike + SU-E2 + SU-E4 | ✅ |
| Q5 E sub-unit count | 4 sub-units (E1/E2/E3/E4) | the E decomposition | ✅ |
| Q6 a11y-id audit per surface | distinct fixture names → "none needed" | each .c | ✅ |

## Decisions Made → enforced where

| Decision | Enforced in |
|---|---|
| D-U3-1 reuse LIVE harness; harness change only if a spike proves it | all SUs; SU-D0 (Q1 may need a tweak) | ✅ |
| D-U3-2 provenance via real seam, hermetic (AN-001) | each SU intro + Execution | ✅ |
| D-U3-3 negative controls MUTATION-verified | each .b + TDD Requirements | ✅ |
| D-U3-4 C/D/E embed NO clock → no SU0-style source touch | Determinism landmines + each SU (no clock fixture) | ✅ |
| D-U3-5 coverage NOT gated this unit | each .c (`COVERAGE_DIRS`/allowlist UNCHANGED) + Code Coverage Requirements | ✅ |
| D-U3-6 selective a11y identifiers | each .c | ✅ |
| D-U3-7 no PR; autonomous; review gate substitutes for signoff | Execution + Status | ✅ |

## Completion Criteria → testable in

| Criterion | Where verified |
|---|---|
| Complete enumerated state-set per surface (P4c/P4e) | each .a (states) + each .b (non-redundant record) | ✅ |
| Every fixture provenance-built (P2) | each .a/.b (assert at call site) | ✅ |
| ≥1 mutation-verified negative control per surface | each .b | ✅ |
| Determinism P3 (no machine path/clock/UUID; twice-run; AN-001) | each .b | ✅ |
| Unreachable states → leaf or observation, never fabricated | Notes (scan = NONE this unit) + spikes STOP-and-surface | ✅ |
| a11y-id decision recorded per surface | each .c | ✅ |
| Running views-lib coverage % recorded | each .c | ✅ |
| 100% coverage on NEW code; views lib NOT gated | Code Coverage Requirements + each .c gate | ✅ |
| Gates: strict build/test, `--uisurfacetest`, `check-coverage.sh` unchanged, ~268 grep-guards | Execution + each .c (run before done) | ✅ |
| One commit per sub-unit; no AI attribution; SerpentGuide unstaged | Execution + each .c | ✅ |
| Fresh review gate; zero surviving CRITICAL/HIGH (P5) | Execution + Status (pre-READY + pre-merge) | ✅ |

## Result

**FULL COVERAGE CONFIRMED — nothing dropped.** Every planning In-Scope item, resolved fork (Q1–Q6), Decision (D-U3-1…7), and Completion Criterion maps to a doing unit/phase. No missing units. The only "not-yet-done" item is the fresh review gate itself, which by design runs AFTER the conversion passes and BEFORE the doc flips to READY_FOR_EXECUTION.
