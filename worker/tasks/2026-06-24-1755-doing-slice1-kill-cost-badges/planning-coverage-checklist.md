# Planning Coverage Checklist — Slice ① (kill cost badges)

Maps every Slice-①-relevant planning-doc requirement to a doing unit. Only Slice ① is converted now; Slices ②–⑤ are forward-declared in the master plan and intentionally NOT covered here.

## In-Scope items (planning) → doing unit
- ✅ Remove `$X tok` `MetricChip` from sidebar terminal rows → Unit 1b (delete :3828-3831 block)
- ✅ Remove cost tooltip (`tokenHelp`) → Unit 1b (delete :3868-3874)
- ✅ Remove dead `compact(_:)` helper → Unit 1b (delete :3876-3880); single-caller baseline → Unit 1a
- ✅ Remove `usd`/"tokens" clause from accessibility label → Unit 1b (delete :3889)
- ✅ Replace with NOTHING (no work-context chip added) → Unit 1b adds nothing; scope reminder enforces

## Decisions (planning) → doing reflection
- ✅ D1 (presentation-only; Core pricing retained) → Unit 1c verifies `SessionActivity.swift` UNCHANGED; Core tests pass unmodified
- ✅ D2 (⚡/💤 are health glyphs, kept) → Scope reminder OUT-list; Unit 1a positive-guard keeps `healthGlyph`
- ✅ D3 (no test/surface coupling) → TDD note explains App has no XCTest seam; Unit 1c runs `--uisurfacetest` smoke

## Completion criteria (planning, Slice-① relevant) → doing
- ✅ 100% coverage on new code → Coverage section: no new Core code; `check-coverage.sh` stays green, allowlist unchanged (Unit 1c)
- ✅ All tests pass → Unit 1c `swift test` strict
- ✅ No warnings → Unit 1b/1c `swift build`/`swift test` warnings-as-errors

## Hard constraints (task brief) → doing
- ✅ Strict build/test flags (`-warnings-as-errors -strict-concurrency=complete`) → Completion Criteria + Units 1b/1c
- ✅ `check-coverage.sh` + allowlist must not grow → Unit 1c
- ✅ One commit per fix/unit → Commit policy (single commit justified: warnings-as-errors forbids non-building intermediates)
- ✅ NO Co-Authored-By / AI attribution → Commit policy + Completion Criteria
- ✅ Do NOT stage `SerpentGuide.ouro/` → Execution + Completion Criteria
- ✅ Preserve auditability/recovery truth → no recovery/audit path touched (presentation-only); health/attention context preserved (D2)
- ✅ Locate exact render site myself (grep) → done; recorded in master plan Context (render :3828-3831)
- ✅ Verify nothing else depends on that view state → Unit 1a checks `TerminalAgentRow` guard (:3635) depends on `activity != nil`, not `usdLabel`; validation confirmed only cost surface

## Auditability / error-handling / trust gating
- ✅ No error paths added (pure deletion, no new logic)
- ✅ No trust/security gating involved in this slice
- ✅ Audit truth preserved: cost was a UI surface, not a recovery/provenance signal; removing it changes no classification (resumed/respawned/manual)

## Gaps found
- None. Every Slice-① planning requirement has a doing unit. Slices ②–⑤ intentionally deferred (forward-declared in master plan; converted at their turn).
