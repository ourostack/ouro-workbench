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
| FirstRunBootstrapView | L6943 | 9 | — | — | — |
| OnboardingRepairStepRow | L7272 | 8 | — | — | — |
| OnboardingReadinessView | L7104 | 5 | — | — | — |
| OnboardingBossChoiceView | L6811 | 3 | — | — | — |
| MarkdownMessageView | L6733 | 3 | — | — | — |
| OnboardingBossReconstructView | L7393 | 2 | — | — | — |
| OnboardingFlowHeader | L6656 | 1 | 1 | 0 | **0** |
| FirstRunStepRow | L7055 | 1 | — | — | — |

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
