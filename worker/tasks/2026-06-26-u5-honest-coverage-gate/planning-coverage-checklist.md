# Planning coverage checklist — brief → doing-doc unit mapping

The "planning doc" is the operator's U5 brief (firm decisions Q1=SPLIT, Q2=SNAPSHOT). Every requirement
mapped to a doing-doc unit. ✅ = has a unit; ❌ = MISSING (none).

## Scope item 1 — Extract WorkbenchViewModel
- ✅ Extract VM (+ pure-behavioral helpers/extensions, not views) into NEW `WorkbenchViewModel.swift` → Unit 1b
- ✅ Leave 127 view structs in the file; consider rename to `WorkbenchViews.swift` → Unit 1b + D1
- ✅ Same-module move → access stays internal → no reference breaks → Unit 1a/1b (extract-plan.md)
- ✅ RISK: private/fileprivate shared members → promote ONLY those to internal, minimal, note each →
  Unit 1a/1b (N=3: ProviderCheckProcessResult, BossQuickQuestion, bossQuickQuestions; extract-plan.md)
- ✅ prod-byte-identical, pure move + access-widen, build+test green proves no logic changed → Unit 1b acceptance
- ✅ huge but pure code-movement diff → Unit 1b acceptance (normalized-diff check)
- ✅ appSource() union-reader update for new file boundaries → Unit 1b (orderedLibFiles)
- ✅ structural-guard slice markers update for new file boundaries → Unit 1a/1b (M=0 expected; doer re-verifies)

## Scope item 2 — Cover the branchless views
- ✅ Cover the ~28 branchless presentational views → Unit 2 (RE-SCOPED: the measured residual is larger —
  K2 already-snapshotted un-hit regions + K3 branchless; THE FORK in residual-baseline.md + D6)
- ✅ RECONFIRM which remain uncovered (several covered/transitively-covered in C11) → Unit 0 (post-split
  re-measure + per-view bucketing)
- ✅ For each genuinely-uncovered: one provenance-built snapshot pinning rendered content → Unit 2a/2b
- ✅ mutation-verify the CONTENT catch (mutate rendered Text/Image → RED → revert) → Unit 2c
- ✅ deterministic (no leaks/clocks; reuse proven recipes) → Unit 2a + D7
- ✅ genuinely-nodeless views (pure Color/Divider/frame) → allowlist w/ "nodeless, captures nothing" → Unit 0 classify + Unit 3 allowlist
- ✅ NOT fabricated → Unit 2a ②b-law guard (genuinely-unreachable → recorded carve, not contorted test)

## Scope item 3 — Wire the gate
- ✅ Add the views file to COVERAGE_DIRS in check-coverage.sh → Unit 3 (D2: gate ONLY the views file, not the dir)
- ✅ HONEST per-file allowlist sized to ONLY genuinely-untestable carves → Unit 3 (K1-only)
- ✅ the 8 dossiered carves (live-TerminalPane arms, MachineRuntimeView/LoginItemController login rows,
  unreachable @State-no-seam arms BossDashboardView.showsAdvanced/DecisionInboxSheet.showFullLog,
  AboutSheet-if-nodeless) → Unit 3 (traces to allowlist-candidates.md #1–#8)
- ✅ + any nodeless-view lines from step 2 → Unit 3
- ✅ budget MUST be MINIMUM that passes; measure exact residual after steps 1-2; comment per carve → Unit 3 acceptance
- ✅ do NOT pad the budget → Unit 3 + D6 (K2 NOT allowlisted)
- ✅ WorkbenchViewModel.swift NOT added to COVERAGE_DIRS (document why) → Unit 3 + Code Coverage Reqs + D2

## Constraints
- ✅ strict build 0-warn (warnings-as-errors + strict-concurrency=complete) → Execution per-PR gates (preflight)
- ✅ full swift test 0-fail → Execution per-PR gates
- ✅ --uisurfacetest green → Execution per-PR gates (preflight)
- ✅ check-coverage.sh green (Core/ShellAdapter stay 100%; views file after step 3) → Execution + Unit 3
- ✅ structural guards green → Execution per-PR gates (assertEveryLibFileIsOrdered)
- ✅ One commit per sub-unit → Execution
- ✅ NO AI attribution → Execution
- ✅ NEVER stage SerpentGuide.ouro/ / default.profraw / *.actual.txt → Execution + Unit 2c/R
- ✅ reuse proven recipes (workbenchTimeText+cross-TZ, AN-001 dual-injection, path-leak fixed paths,
  standalone .popover/.contextMenu, Menu{} descended) → D7 + Unit 2a
- ✅ ViewModel-extract PR lands FIRST + verified pure-move; steps 2-3 build on it → PR decomposition (serial, PR#1 first)

## Git
- ✅ Fresh branch off origin/main (fetch + checkout -b … origin/main) → DONE (u5-honest-coverage-gate @ 687b6c7) + Execution
- ✅ doing doc under worker/tasks/ (2026-06-26-…) → worker/tasks/2026-06-26-u5-honest-coverage-gate.md
- ✅ terse campaign-journal pointer → Unit R acceptance (written when doc flips done) — see note below
- ✅ commit (docs(doing):) → all commits use docs(doing): prefix
- ✅ No PR → D5 + Execution

## Autonomy / review
- ✅ Fully autonomous (operator trusts the plan) → D4 (execution_mode=spawn)
- ✅ fresh unbiased sub-agent review gate before READY → Unit R
- ✅ for ambiguity pick the reversible default, record it → D1/D2/D3/D6 (each a reversible default, recorded)

## Return-to-operator deliverables (the brief asks me to RETURN these — they are NOT doc units, they are
## my final message; tracked here so I don't drop one)
- ✅ doing-doc path + PR decomposition (how many PRs, sequence)
- ✅ ViewModel-extract risk analysis (promotions count, VM-vs-views size, appSource/guard retargets)
- ✅ branchless-view list RECONFIRMED (still-uncovered+snapshot-able vs nodeless) — with THE FORK caveat
- ✅ projected final allowlist (carve entries + sizes) — confirm minimal/honest — with THE FORK caveat
- ✅ any genuine fork worth surfacing → THE FORK (D6) is the headline

## Gaps found during this check
- The campaign-journal pointer (brief: "terse campaign-journal pointer") is currently only referenced in
  Unit R acceptance ("written when the doc flips done"). That is correct sequencing (the pointer should be
  written at completion, not now) — recorded here so it is not forgotten. NOT a missing unit.
- No other gaps. Full coverage confirmed.
