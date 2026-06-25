# Doing: Slice ① — Kill Per-Tab Cost Badges

**Status**: DONE
**Execution Mode**: direct
**Created**: 2026-06-24 17:57
**Planning**: ./2026-06-24-1755-planning-workspaces-converged-design.md
**Artifacts**: ./2026-06-24-1755-doing-slice1-kill-cost-badges/

## Execution Mode

- **pending**: Awaiting user approval before each unit starts (interactive)
- **spawn**: Spawn sub-agent for each unit (parallel/autonomous)
- **direct**: Execute units sequentially in current session (default) ← **this slice**

Rationale: small, single-file, presentation-only removal. Sequential direct execution; one commit for the slice (units share the same edit site — see Commit policy).

## Objective
Remove the per-tab spend surface (`$X tok`) from the sidebar terminal rows. Replace with nothing. Keep work-context health glyphs (⚡/💤 = `AttentionState` health, NOT spend) and the todo mini. Keep the Core pricing model (`SessionActivity.usd`/`.usdLabel`, `SessionPricing`) untouched — this is presentation-only and reversible.

## Scope reminder (do NOT scope-creep)
- IN: remove the `MetricChip(label: "tok", value: usd)` render + its `tokenHelp` tooltip + the now-dead `compact(_:)` helper + the `usd` clause in the chip's accessibility label.
- OUT: branch/diffstat/attention work-context chips (later slice). Core `usd`/`usdLabel`/`SessionPricing` deletion (retained — see planning D1). The ⚡/💤 glyphs (health, kept — planning D2).

## Completion Criteria
- [x] No `$X tok` `MetricChip` renders in `SessionChip` (the spend surface is gone).
- [x] `tokenHelp(_:)` and `compact(_:)` removed (dead after the chip removal; no other callers — verified).
- [x] The `usd`/"tokens" clause removed from `SessionChip.accessibilityLabel`.
- [x] `SessionChip` still renders health glyph + todo mini; the `TerminalAgentRow` guard `activity != nil || isStalled` at OuroWorkbenchApp.swift:3635 remains valid (the chip is non-empty whenever shown — see Unit 1a check).
- [x] Core `SessionActivity.usd`/`.usdLabel` + `SessionPricing` UNCHANGED; their tests still pass unmodified.
- [x] `swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` — 0 warnings, 0 errors.
- [x] `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` — 0 failures.
- [x] `swift run -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete OuroWorkbench --uisurfacetest` passes (rendering smoke; no crash).
- [x] `Scripts/check-coverage.sh` passes; `Scripts/coverage-allowlist.txt` does NOT grow (no Core change, so coverage is unaffected — confirm green).
- [x] 100% test coverage maintained on all Core code (no new Core code added; gate stays green).
- [x] `SerpentGuide.ouro/` NOT staged. No Co-Authored-By / AI attribution in the commit.

## Code Coverage Requirements
**MANDATORY: 100% coverage on all new code.**
- This slice adds NO new Core/ShellAdapter code — it only deletes App-side render. So `check-coverage.sh` must remain green with `coverage-allowlist.txt` unchanged.
- App target (`OuroWorkbenchApp`) is not coverage-gated (GUI shell) but IS compiled under warnings-as-errors + strict-concurrency-complete.
- Core pricing tests (`SessionActivityTests.swift`, `TailCoverageTests.swift`) MUST still pass unmodified — proof the Core model was left intact.

## TDD Requirements

**Honest TDD note — App target has no unit-test seam.** The only test target is `OuroWorkbenchCoreTests` (Core + ShellAdapter); `OuroWorkbenchApp` is an executable with no XCTest target, and SwiftUI views in it cannot be XCTest-asserted for rendered glyphs. Do NOT fabricate an XCTest for `SessionChip` — it is not test-visible.

The red→green discipline for this pure App-side removal is encoded as a **source-level regression guard** plus the compiler/render smoke:

1. **Red**: Add a regression-guard check (Unit 1a) that asserts the spend tokens are ABSENT from `OuroWorkbenchApp.swift`. Run it now — it FAILS (the tokens are present). This is the failing-test step.
2. **Verify failure**: the guard reports the spend tokens present (red).
3. **Minimal implementation**: remove exactly the spend render + dead helpers (Unit 1b).
4. **Verify pass**: the guard passes (green); `swift build` strict passes; `swift test` strict passes; `--uisurfacetest` passes.
5. **Refactor/confirm**: confirm no orphaned references, Core untouched (Unit 1c).
6. **No skipping**: do not remove code before the guard is failing-red and recorded.

The guard is a shell assertion saved under the artifacts dir, not a Swift XCTest (because the App target has no test seam). This is the truthful equivalent of "failing test first" for a no-logic, view-only deletion.

## Work Units

### Legend
⬜ Not started · 🔄 In progress · ✅ Done · ❌ Blocked

### ✅ Unit 1a: Spend-removal regression guard — Tests (RED)
**What**:
- Write `./2026-06-24-1755-doing-slice1-kill-cost-badges/guard-no-cost-badge.sh`: greps `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` and FAILS (exit 1) if ANY of these spend tokens are present:
  - `MetricChip(label: "tok"` (the `$X tok` render)
  - `func tokenHelp` (cost tooltip helper)
  - `about \(usd) tokens` (accessibility cost clause)
- The guard must ALSO assert the KEPT surfaces are still present (so a later refactor can't silently strip health/todo): `healthGlyph`, `todoMini`, `MetricChip` is still defined as a struct (kept primitive). Keep these positive checks narrow to avoid brittleness.
- Pre-removal baseline check: grep-confirm `compact(` has exactly one caller (`tokenHelp`) before declaring it dead — record the result in `./2026-06-24-1755-doing-slice1-kill-cost-badges/compact-callers.txt`. (Known at plan time: only line 3871 inside `tokenHelp` calls `compact`; lines 3943-3944 are `chevron.compact.*` SF Symbol strings, NOT calls.)
- Pre-removal guard check: grep-confirm `TerminalAgentRow` guard `activity != nil || isStalled` (:3635) does not depend on `usdLabel` — it depends on `activity != nil`, which stays true for todo-only activity, so the chip is still meaningfully populated.
**Output**: executable `guard-no-cost-badge.sh`; `compact-callers.txt` baseline.
**Acceptance**: Running the guard now FAILS (red) on the three spend tokens; `compact-callers.txt` shows exactly one real caller; the guard's positive (kept-surface) checks PASS.

### ✅ Unit 1b: Remove the spend render — Implementation (GREEN)
**What**: In `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`, make exactly these edits in `struct SessionChip`:
1. Delete the cost-render block in `body` (currently :3828-3831):
   ```swift
   if let activity, let usd = activity.usdLabel {
       MetricChip(label: "tok", value: usd)
           .help(tokenHelp(activity))
   }
   ```
   (Remove the whole `if let` block. The preceding `if let activity, let todoLabel = activity.todoLabel { todoMini(...) }` and the `healthGlyph` stay.)
2. Delete `tokenHelp(_:)` (currently :3868-3874).
3. Delete `compact(_:)` (currently :3876-3880) — dead after (2); confirmed single caller in Unit 1a.
4. In `accessibilityLabel` (currently :3882-3892), delete the line `if let usd = activity.usdLabel { pieces.append("about \(usd) tokens") }` (:3889). Keep the health-label and todo pieces.
**Verify the chip is never empty when shown**: after removal, `SessionChip.body` renders `healthGlyph` (always) + optional `todoMini`. The `TerminalAgentRow` guard at :3635 (`activity != nil || isStalled`) still gates it; `healthGlyph` always renders, so no empty chip. (Confirm by reading the post-edit `body`.)
**Output**: edited `OuroWorkbenchApp.swift` (4 deletions, no additions).
**Acceptance**:
- `./2026-06-24-1755-doing-slice1-kill-cost-badges/guard-no-cost-badge.sh` now PASSES (green) — all three spend tokens absent, kept-surfaces present.
- `swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` — 0 warnings/errors (proves `compact`/`tokenHelp` were truly dead; an unused-but-undeleted helper or orphan call would warn/error).

### ✅ Unit 1c: Verify Core untouched + full gates (GREEN, confirm)
**What**:
- `git diff --name-only` shows ONLY `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` changed (plus the artifacts dir). Confirm `Sources/OuroWorkbenchCore/SessionActivity.swift` is UNCHANGED (Core pricing model retained — planning D1).
- Run `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` — Core pricing tests pass unmodified.
- Run `swift run -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete OuroWorkbench --uisurfacetest` — rendering smoke passes (no crash; the row still renders).
- Run `Scripts/check-coverage.sh` — passes; `git diff Scripts/coverage-allowlist.txt` empty (allowlist did not grow).
- Save each command's tail output to `./2026-06-24-1755-doing-slice1-kill-cost-badges/gate-output.txt`.
**Output**: `gate-output.txt` with build/test/uisurface/coverage results.
**Acceptance**: all four gates green; only the App file changed; allowlist unchanged; Core diff empty.

## Execution
- **TDD strictly enforced (App-adapted)**: regression guard red → remove → guard green → build/test/uisurface/coverage green. See TDD Requirements for why the "test" is a shell guard, not an XCTest.
- **Commit policy**: one commit for the slice. The three units edit the same `SessionChip` and the change is a single atomic removal — splitting into 1b/1c commits would push a non-building intermediate (deleting the render but leaving `tokenHelp`/`compact` referenced, or vice versa, fails warnings-as-errors). So: stage `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` only, commit once after all gates pass. Suggested message: `feat(sidebar): remove per-tab cost badge ($X tok) from terminal rows`. NO Co-Authored-By / AI attribution.
- **Do NOT stage** `SerpentGuide.ouro/` or the artifacts dir contents that aren't part of the doc trail (the `.sh` guard + `.txt` baselines MAY be committed under `worker/tasks/.../` as audit trail, but NEVER `SerpentGuide.ouro/`).
- Push after the unit completes (per repo workflow).
- **All artifacts**: save guard script + baselines + gate output to `./2026-06-24-1755-doing-slice1-kill-cost-badges/`.
- **Fixes/blockers**: if a gate fails unexpectedly (e.g. a hidden second caller of `compact`, or a surface test that DID couple to the cost chip), spawn a sub-agent to investigate immediately; update this doc + commit.
- **Decisions made**: update docs immediately, commit right away.

## Progress Log
- 2026-06-24 17:57 Created from master plan; Slice-① anchors re-confirmed exact (render block :3828-3831 with `MetricChip` on :3829, tokenHelp :3868-3874, compact :3876-3880, a11y :3889). Anchors were verified against the source tree at branch-point 44f06e2 (the doc commits since are docs-only — no source change — so the lines remain exact).
- 2026-06-24 18:01 Fresh unbiased sub-agent review gate PASSED: all 8 claims CONFIRMED against real source (render site, single compact() caller, a11y clause, ⚡/💤=health-not-spend, Core pricing test-covered/kept, no missed cost surface, no UI-surface coupling, body never empty + guard independent of usdLabel). Verdict: SAFE to execute as written. Status → READY_FOR_EXECUTION confirmed.
- 2026-06-24 18:06 Unit 1a complete (RED): wrote `guard-no-cost-badge.sh` (3 negative spend-token asserts + 3 positive kept-surface asserts) — ran it, FAILED red (all three spend tokens present: `MetricChip(label: "tok"`, `func tokenHelp`, `about \(usd) tokens`). Recorded `compact-callers.txt` baseline: `compact(` has exactly ONE real caller (line 3871 in `tokenHelp`); line 3876 is the def; lines 3943-3944 are `chevron.compact.*` SF Symbol strings (not calls). Re-confirmed `TerminalAgentRow` guard :3635 = `activity != nil || isStalled` (independent of `usdLabel`).
- 2026-06-24 18:17 Unit 1b complete (GREEN): made the 4 scoped deletions in `struct SessionChip` (cost-render `if let` block in `body`, `tokenHelp(_:)`, dead `compact(_:)`, the `usd` a11y clause) + updated the now-stale `SessionChip` doc-comment that still described the removed token/$ `MetricChip` (doc truth, no behavior change). Guard now PASSES green. `swift build` strict (`-warnings-as-errors -strict-concurrency=complete`) = Build complete, 0 warn/0 err — proving `tokenHelp`/`compact` were truly dead. Health glyph (always) + todo mini kept; body never empty.
- 2026-06-24 18:17 Unit 1c complete (gates GREEN): `git diff --name-only` = ONLY `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` (Core `SessionActivity.swift` diff empty; `coverage-allowlist.txt` diff empty). `swift test` strict = 2708 tests, 1 skipped, 0 failures. `--uisurfacetest` = all surfaces ok, no crash. `Scripts/check-coverage.sh` = PASS (100% line+region; allowlist unchanged — same 2 pre-existing entries). NOTE: the FIRST coverage run aborted on flaky `DaemonLivenessTests.testDefaultReachabilityReturnsFalseForNonHTTPResponse` (`NSURLErrorTimedOut -1001` on a cold `URLSession` file:// probe with 0.1s timeout) — unrelated to this App-only change (Core test, passed in the strict `swift test` run and on isolated retry in 0.013s); clean re-run green. Code commit `d69b6a7` `feat(sidebar): remove per-tab cost badge ($X tok) from terminal rows` (only the App file staged; `SerpentGuide.ouro/` NOT staged; no attribution). Branch pushed to `origin/feat/slice1-kill-cost-badges`. Status → DONE.
