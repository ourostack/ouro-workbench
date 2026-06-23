# Doing: Boss action-log pending state (false-success / unverified green checkmark)

- **Status:** in progress
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

### Unit 2 — App wiring + render through the seam ⬜
1. `WorkbenchActionLogEntry` (Core): add `var isInFlight: Bool` default false +
   backward-compatible decode (custom `init(from:)` w/ `decodeIfPresent ?? false`,
   since synthesized Codable throws on a missing non-optional key).
2. `recordActionLog` + `finishBossAction`: add `isInFlight: Bool = false`, thread in.
3. Mark the 6 genuinely-async start handlers' post-`Task{}` acks `isInFlight: true`:
   `startRepairAgent`, `startVerifyProvider`, `startRefreshProvider`,
   `startSelectLane`, `startRegisterWorkbenchMCP`, `startEnsureDaemon`.
   `openProviderConfig` stays false (synchronous — `presentProviderConfigForm` is
   final, no async Task, no `complete*`). `startReportBug` stays false (its `Task`
   has NO `complete*` verified-outcome row, so pending would never resolve). Guard
   skips + `complete*` calls stay false.
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
- [ ] Unit 2 wiring shipped; 6 handlers marked in-flight; render routed through seam
- [ ] Old persisted `actionLog` JSON (no `isInFlight`) still decodes → false
- [ ] Real failures (guard-skip, `complete*` succeeded:false) still render orange
- [ ] Full `swift test` green, warnings-as-errors + strict-concurrency clean
- [ ] Committed per unit + pushed; NOT merged/PR'd

## Progress log
