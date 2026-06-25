# U0 Planning Coverage Checklist (Pass 5)

Systematic check: every campaign-doc U0 requirement + every hard-safety constraint from the task brief maps to a doing unit. ✅ = has a unit; ❌ = MISSING.

## From campaign doc (`2026-06-24-anneal-visual-testing.md`, U0 row + acceptance + decisions)

| # | Campaign U0 requirement | Doing unit | Status |
|---|---|---|---|
| 1 | New `OuroWorkbenchAppViews` library; move the 121 views + `WorkbenchViewModel` | Unit 1 (target + first view), Unit 3 (VM + core), Unit 4 (remaining views) | ✅ |
| 2 | Thin executable keeps `main.swift`/`App`/`AppDelegate`/`TerminalPane` | Layout section + Unit 3 (App scene stays, imports lib) + Unit 4g. NOTE: `TerminalPane` moves to lib-allowlisted (recorded amendment) — App/AppDelegate/main.swift stay genuinely | ✅ (with recorded D-A5 amendment) |
| 3 | Update `appSource()` to read the new lib dir (decouple the grep guards) — do this EARLY | Unit 2 (retarget + de-duplicate 43 copies); sequenced before/with first guarded move | ✅ |
| 4 | Decompose into smallest safe increments; first PR minimal + proves build/test/harness end-to-end on ≥1 view | Unit 1 (keystone: empty lib + proof test + ONE leaf view) | ✅ |
| 5 | No behavior change; strict flags green | Completion Criteria + every unit's Acceptance ("no behavior change", strict-flag green) + Unit 6 diff-audit | ✅ |
| 6 | New lib builds; executable depends on it | Unit 1 (Package.swift wiring) + Completion Criteria | ✅ |
| 7 | `swift build`/`swift test` green under strict flags (ignore 3rd-party `SwiftTermFuzz`) | Completion Criteria (explicit "ignore SwiftTermFuzz") + Unit 6 | ✅ |
| 8 | New `OuroWorkbenchAppViewsTests` with ≥1 real XCTest that `@testable import`s the lib + constructs a view | Unit 1 (`ImportabilityProofTests.swift`) + Completion Criteria | ✅ |
| 9 | `--uisurfacetest` still passes; no behavior change | Completion Criteria + every unit Acceptance + Unit 3 (UISurfaceTest imports lib) | ✅ |
| 10 | Grep-guard suite passes after EACH increment (count stays green throughout) | Unit 2 + every unit's Acceptance ("guards green") + the regression-locked TDD section | ✅ |
| 11 | Access control: cross-boundary types become `public`; rest `internal`; watch `@MainActor` across module boundary under strict-concurrency-complete | Access-control landmine section + Unit 3 (`@MainActor`/`public` resolution) + "Access-control/strict-concurrency landmines" | ✅ |
| 12 | No coverage-gating yet (that's U4) BUT lib structured so U4 can add to `COVERAGE_DIRS` cleanly; lifecycle code (`@main`/`App`/`AppDelegate`/`TerminalPane`) allowlistable OUTSIDE the gated lib | Unit 5 (coverage-gate readiness, NOT gating) + Code Coverage Requirements + the amendment (PTY allowlisted in-lib; @main/App/AppDelegate genuinely outside) | ✅ |
| 13 | SAFETY VALVE: if extraction can't be done without breaking strict-concurrency/behavior or only as unreviewable big-bang → STOP + report | Execution section (SAFETY VALVE, campaign-mandated) + Unit 3 Acceptance (valve point) | ✅ |
| 14 | D-A1 incremental, not big-bang | Whole decomposition (Units 0-6, batch PRs); serialized merges | ✅ |
| 15 | D-A5 honest verified allowlist > test contortion | "Decision: boundary amendment" + Unit 5 (pre-justified allowlist plan) | ✅ |

## From task brief hard-safety constraints

| # | Task-brief constraint | Doing unit | Status |
|---|---|---|---|
| 16 | Decompose into SMALLEST safe independently-green increments; state decomposition explicitly | Units 0-6 + Unit 4a-4g; "Objective boundary" + layout state it explicitly | ✅ |
| 17 | Grep-guard decoupling FIRST/SAME-PR; guard count green throughout; verify after each increment | Unit 2 (sequenced first) + every Acceptance | ✅ |
| 18 | Access control public/internal; watch `@MainActor` across module boundary under strict-concurrency-complete | Access-control landmine + Unit 3 | ✅ |
| 19 | No behavior change; no coverage-gating yet; lib structured for U4; lifecycle code OUTSIDE gated lib | #5, #12 above | ✅ |
| 20 | SAFETY VALVE: STOP + report if can't be done safely | #13 above | ✅ |
| 21 | Branch `feat/anneal-views-lib-extract` (do NOT create new); doc under campaign subdir; commit `docs(doing):`; no PR | Header (branch noted, "do NOT branch"); doc IS in the subdir; commits are `docs(doing):`; no PR opened | ✅ |
| 22 | Return: doing-doc path + increment decomposition (how many PRs, what each) | Captured in final return message (not the doc) | ✅ (return message) |
| 23 | Return: exec↔lib boundary chosen + `appSource()` decoupling mechanism | "Objective boundary" + layout + Unit 2 | ✅ |
| 24 | Return: riskiest aspect + mitigation OR tripped valve + blocker | Execution (riskiest = Unit 3) + return message | ✅ |
| 25 | Return: access-control/strict-concurrency landmines found | Access-control landmine + Unit 3 + return message | ✅ |

## Verdict

**Full coverage confirmed. Zero ❌.** Every campaign U0 requirement and every task-brief hard-safety constraint maps to a concrete doing unit or recorded decision. The one deviation (TerminalPane in-lib-allowlisted vs physically-outside) is an explicitly-recorded D-A5 amendment, not a dropped requirement.
