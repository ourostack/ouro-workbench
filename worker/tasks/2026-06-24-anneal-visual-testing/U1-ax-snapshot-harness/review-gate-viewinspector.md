# U1 (ViewInspector re-spec) — fresh-sub-agent review gate

A fresh general-purpose sub-agent with NO authoring context reviewed the ViewInspector re-spec of the
U1 doing doc against the rubric (P1–P7), the brief, the constraints, and — critically — ViewInspector's
ACTUAL capabilities (it read the ViewInspector guide/readiness/issues and the ④ source with access
levels). It empirically verified every doc line-citation (`:7299/:7317/:7362/:7367/:7394/:3183/:3190/
:2166/:3775/:3785`) as accurate. Verdict before fixes: **NOT READY — 2 HIGH.** Both resolved below;
re-verdict: **READY.**

## Findings + resolutions

### HIGH (finding 3a) — `find()`-descended children LOSE `@Environment` (ViewInspector issue #317); D-U1-6's environment lever is broken for the ④ nodes; the correct lever is `Text.string(locale:)`.
**Verified** against ViewInspector issue #317 (closed, currently-unresolvable) and `Text.string(locale:
Locale = .testsDefault)` signature. Forcing `.environment(\.locale,…)` on the host root does NOT reach
nodes reached via `find()`, and `.string()` with no arg defaults to `.testsDefault` (≠ `en_US_POSIX`).
**Resolution:** rewrote **D-U1-6** (environment demoted to SECONDARY belt; PRIMARY lever =
`.string(locale: en_US_POSIX)`), **D-U1-VI** (full rationale + `.testsDefault` gotcha), the harness-shape
Pieces 1+2 (serializer reads `.text().string(locale:)`; host extracts via the fixed `Locale`), **Unit 2a/2b**
(red test (v): content pinned by `string(locale:)`, environment-only proven insufficient), **Unit 0**
(spike step (c): verify environment does NOT reach descended nodes + record the `string(locale:)` recipe),
and added **landmine L7**. **CLOSED.**

### HIGH (finding 1) — the proof rests on `find()` evaluating `@ObservedObject` child bodies WITHOUT `ViewHosting`/an `Inspection` hook, but the doc never named that regime or the caveat.
**Verified:** all three ④ structs hold `@ObservedObject var model` (`:7300/:7319/:7365`), which is
ViewInspector's supported no-hosting synchronous-`find()` case; but the doc mentioned neither `ViewHosting`
nor `Inspection`/`Inspectable` anywhere.
**Resolution:** **D-U1-VI** now NAMES the `@ObservedObject`-only / no-`ViewHosting` / no-source-hook regime
as the explicit dependency, with a STOP-and-surface if any descended proof node needs `ViewHosting`/a hook
(a view-source touch = out of U1 scope). **Unit 0** spike step (a) now must CONFIRM child-body invocation
via that exact path, and its Acceptance + STOP condition include "needs a source `Inspection` hook /
`ViewHosting` → STOP + surface." **CLOSED.**

### MEDIUM (finding 2) — the negative-control claim over-reaches: `isEditable()` is a private pure passthrough of `editableFields`, so the data-driven flip catches the `if isEditable` BRANCH WIRING + proves the harness sees the rendered control (the Mirror win), but does NOT catch a regression INTERNAL to the predicate body.
**Resolution:** the harness-shape Honesty note + Unit 4 acceptance now state the control proves exactly
(1) the harness sees rendered `TextField` vs `Text` (Mirror gap) and (2) catches the branch-wiring
regression — and explicitly do NOT claim "catches all view-logic regressions." Commit-message language
constrained to "catches the editable-vs-static **rendering** regression at the control node." A
source-level predicate inversion is noted as needing a test seam (out of U1 scope). **CLOSED (tightened).**

### MEDIUM (finding 3c) — `WorkbenchViewModel.init` spawns a DETACHED `Task` (`sweepStaleWorkbenchBundlesOnLaunch` → `cleanupAllAgents`) that mutates `~/AgentBundles` + shells `git` regardless of temp `paths`.
Not a snapshot-byte issue (declared-content-only output won't include it — L5) but a test-hygiene/flake
hazard the fixture inherits. **Resolution:** added **landmine L8** + Unit 0 spike step (f) to record it.
**ACCEPTED with note.**

### MEDIUM — host `NSHostingView` render-path ("may still construct…") is left to the Unit-0 spike.
Acceptable: Unit 0 is the explicit make-or-break gate that STOPS + surfaces on failure. The doc now ties
the render-pass decision to Unit 0's finding. **ACCEPTED.**

### NIT — `0.10.4` already published; D-U1-DEP's "latest stable" rationale was stale.
**Resolution:** D-U1-DEP updated — exact pin still correct; `0.10.4` noted as the sanctioned exact-pin
fallback if 6.3.2 surfaces an issue on 0.10.3 (never switch to a range pin). **CLOSED.**

## Confirmed COMPLIANT by the reviewer (no change needed)
- Private ④ children reached by ViewInspector DESCENT via the internal `BossProposalCardList` — correctly
  handled (the doc states it repeatedly; access levels confirm direct construction is impossible).
- Test-only dep (only on `OuroWorkbenchAppViewsTests`), pinned exact, `show-dependencies` + product-target
  checks present; F-1 `exclude:` correct + well-explained; allowlist + `COVERAGE_DIRS` unchanged; one
  commit / no AI attribution / `SerpentGuide.ouro/` unstaged; operator-ratification of the dep PROMINENTLY
  flagged (header + D-U1-DEP + F0 + journal). Scope well-disciplined (no full state-sets / broad a11y-id /
  gate / source-touch / grep-guard retirement). TDD-for-snapshots honest; 100%-by-inspection acknowledged.

## Re-verdict
Both HIGH closed (the determinism lever switched to `string(locale:)`; the no-`ViewHosting`
`@ObservedObject` regime named + Unit-0-verified with a STOP gate); MEDIUMs tightened/accepted; NIT folded.
**READY_FOR_EXECUTION.** Residual risk is concentrated in Unit 0, which is explicitly the make-or-break
gate that STOPS and surfaces rather than proceeding on an unproven source.
