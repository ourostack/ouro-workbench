# Doing: Boss action-log pending state (false-success / unverified green checkmark)

- **Status:** done
- **Execution Mode:** direct
- **Branch:** `fix/boss-actionlog-pending-state` (off `main` @ c7d6d63)
- **Artifacts:** `./2026-06-22-1849-doing-boss-actionlog-pending-state/`

## The bug
The boss action LOG shows a GREEN checkmark for in-flight async actions that
haven't completed. `finishBossAction` computes `succeeded: !hasPrefix("Skipped")
&& !hasPrefix("Failed")`; the async "start" handlers kick off background work and
IMMEDIATELY call `finishBossAction` with an optimistic ack — which isn't
Skipped/Failed → logs `succeeded:true` → green check. The VERIFIED outcome lands
LATER via `complete*` handlers as a SEPARATE row. So an unverified in-flight action
wears a green "success" check.

## The fix
Add a PENDING state. A green check must mean a VERIFIED success. In-flight acks
render neutral (pending), never green. Real failures (guard-skips, `complete*`
with `succeeded:false`) STILL render orange — pending never swallows a real failure.

## Units

### Unit 1 — Core presentation seam ✅
`Sources/OuroWorkbenchCore/WorkbenchActionOutcomePresentation.swift`:
`Tone {.pending,.succeeded,.failed}` + `tone(isInFlight:succeeded:)` (pending
dominates) + `iconSystemName(for:)` + `SemanticColor {.neutral,.green,.orange}` +
`color(for:)` + `label(for:)`. Exhaustive switches, no `default`. HONESTY INVARIANT:
green check / `.green` ONLY for `.succeeded`, produced ONLY when
`isInFlight==false && succeeded==true`. 100% line+region; allowlist stays at 2.

- **Acceptance:** tests cover all (isInFlight × succeeded) combos + all Tone arms;
  honesty invariant asserted; `swift test` green; `Scripts/check-coverage.sh` 100%.

### Unit 2 — App wiring + render through the seam ✅
1. `WorkbenchActionLogEntry` (Core): add `var isInFlight: Bool` default false +
   backward-compatible decode (custom `init(from:)` w/ `decodeIfPresent ?? false`,
   since synthesized Codable throws on a missing non-optional key).
2. `recordActionLog` + `finishBossAction`: add `isInFlight: Bool = false`, thread in.
3. Mark the 6 genuinely-async start handlers' post-`Task{}` acks `isInFlight: true`:
   `startRepairAgent`, `startVerifyProvider`, `startRefreshProvider`,
   `startSelectLane`, `startRegisterWorkbenchMCP`, `startEnsureDaemon`.
   `openProviderConfig` stays false (synchronous — `presentProviderConfigForm` is
   final, no async Task, no `complete*`). `startReportBug` IS in-flight (cold-review
   correction): it delegates to the async `submitBugReport(…)`, which writes the
   bundle off-main and records the VERIFIED outcome later via
   `recordActionLog(action: "submitBugReport", …)`. That settled row logs under a
   different `action` than the optimistic ack, so on failure both rows persist — a
   green "Writing…" beside the orange "Failed". Marking the optimistic ack
   `isInFlight: true` makes the later `submitBugReport` row the settled truth.
   Guard skips + `complete*` calls stay false.
4. `actionLogEntryRow` (~7522-7523): route icon+color through the seam. (The
   `HarnessActionResultBanner` at ~1571 renders a *different* type,
   `HarnessActionResult` — always a settled/verified outcome, never in-flight — so
   it is NOT touched; the spec's 1571 anchor was a mis-anchor.)
5. Core round-trip/decode test: old JSON without `isInFlight` decodes → false.
   Source-pin test: 6 in-flight acks pass `isInFlight: true`; guard/`complete*`
   paths don't; `actionLogEntryRow` routes through `WorkbenchActionOutcomePresentation`.

- **Acceptance:** `swift build`/`swift test` with `-warnings-as-errors
  -strict-concurrency=complete` green; coverage 100%; old-JSON decode test green.

## Completion Criteria
- [x] Unit 1 Core seam shipped, 100% line+region, allowlist at 2
- [x] Unit 2 wiring shipped; 6 handlers marked in-flight; render routed through seam
- [x] Old persisted `actionLog` JSON (no `isInFlight`) still decodes → false
- [x] Real failures (guard-skip, `complete*` succeeded:false) still render orange
- [x] Full `swift test` green, warnings-as-errors + strict-concurrency clean
- [x] Committed per unit + pushed; NOT merged/PR'd

## Progress log
- 2026-06-22 19:03 Unit 1 complete: WorkbenchActionOutcomePresentation seam shipped; 16 tests; Core 100% line+region; allowlist still 2; full suite 2517 pass.
- 2026-06-22 19:11 Unit 2 complete: isInFlight threaded through WorkbenchActionLogEntry (backward-compatible decode), recordActionLog/finishBossAction, 6 async start handlers marked in-flight; actionLogEntryRow routed through the seam. swift build clean (warnings-as-errors + strict-concurrency=complete); full suite 2529 pass / 0 fail; Core 100% line+region; allowlist still 2.
- 2026-06-22 19:11 All units complete; all gates passed (impl-coverage, build clean w/ strict flags, PR review). Status → done. NOT merged/PR'd per mandate. Notes: openProviderConfig + startReportBug deliberately NOT in-flight (synchronous / no verified follow-up row). HarnessActionResultBanner (~1571) NOT touched — it renders HarnessActionResult (a settled synchronous outcome, no in-flight state), so the spec's 1571 anchor was stale. Residual follow-up (out of spec scope): BossActionReceiptSummary.okCount still counts an in-flight ack as "ok" — the pending entry is superseded seconds later by the verified complete* row, so the "N ok" count can briefly double-count; a future change could exclude isInFlight from okCount.
- 2026-06-22 19:34 Cold-review corrections (3 residual false-greens of the same class). (1) BUG: startReportBug WAS a residual false-green — its prior "deliberately NOT in-flight" rationale was wrong. submitBugReport is async and records the verified outcome later under action="submitBugReport", a DIFFERENT action than the optimistic ack, so on failure both a green "Writing…" and an orange "Failed" row persist. Marked the post-call ack isInFlight: true; flipped the source-pin test (now asserts startReportBug's optimistic ack IS in-flight, its guard ack is NOT). (2) BUG: BossActionReceiptSummary.okCount counted in-flight acks as "ok" (the residual flagged above). Fixed by excluding in-flight from the DENOMINATOR (settled = considered.filter{!isInFlight}; ok/failed derived from settled) — NOT by adding !isInFlight to the failed filter (which would push pending into the ok bucket). (3) FOLDED IN: BossAgentPromptBuilder labeled every succeeded entry "ok" to the boss, so an in-flight ack reported outcome=ok — now labeled "in progress"; settled success stays "ok", settled failure stays "skipped". +7 Core tests. swift build + full suite (2536 pass / 1 skip / 0 fail) clean w/ -warnings-as-errors -strict-concurrency=complete; Core 100% line+region; allowlist still 2. New commit(s) on fix/boss-actionlog-pending-state; NOT merged/PR'd.
