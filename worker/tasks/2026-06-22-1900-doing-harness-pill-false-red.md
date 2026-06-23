# Doing: Fix Harness Status sheet false-RED transient (boss reachability + pending grace)

- **Branch:** `fix/harness-pill-false-green` (continuation; off `main` @ 335967d, HEAD `0401191`)
- **Execution Mode:** direct
- **Artifacts:** `./2026-06-22-1900-doing-harness-pill-false-red/`
- **Status:** done

## The bug (the F7 inverse of the false-green this branch fixed)
The branch made the per-agent pill + `readyCount` live-aware (green only on `.working`) —
correct. But it also routed **boss reachability** and the **overallState/headline rollup**
through that same live verdict, introducing a FALSE-RED transient:

- `HarnessBossReachability.bundleIsReady` keyed on the boss entry's live `isReady`
  (requires `.working`). On first sheet open per session the boss's check is still in flight
  → boss reads NOT reachable → `overallState == .blocked` → red "Blocked" pill + headline
  "Boss <X> is not reachable" for a perfectly healthy daemon-up + MCP-registered +
  config-installed boss, for ~15s, until the verdict lands.
- `HarnessAgentInventory.hasUnready` counts PENDING (in-flight `.checking` / no-verdict-yet
  `.unverified`) agents as "unready" → `overallState` flaps to `.attention` on every launch
  with no real problem.

The branch's own tests `testInFlightAgentIsNotReady` /
`testBossWithExpiredTokenIsNotReachable` (and `testConfigReadyWithoutAnyLiveCheckIs…`)
ASSERT this false-RED as if correct — they must be corrected.

## The correct model — three rollup states, not two
- **ready** — live verdict `.working` (`liveReadiness == .ready`). Counts in `readyCount`.
- **pending** — `.checking` (in flight) or `.unverified` (no verdict yet). NOT ready, NOT alarm.
- **problem** — confirmed bad: `.authExpired` / `.vaultLocked` / `.unreachable`, plus config
  problems `.disabled` / `.missingConfig` / `.invalidConfig`. Counts as unready-alarm.

Separately: **reachability ≠ readiness.** "Reachable" = bundle CONFIG-installed
(`status == .ready`) + MCP registered + daemon up. The outward-provider health belongs ONLY
on the per-agent pill (and in `hasUnready`/`readyCount` when CONFIRMED bad), never in
reachability.

## Units

### Unit 1 (Core) — pending classification helper + decouple `hasUnready`
- Add `var rollupReadiness` classification (ready / pending / problem) derived from
  `liveReadiness` on `HarnessAgentEntry`. Expose `isPending` / `isProblem`.
- `HarnessAgentInventory.hasUnready` = any entry `isProblem` (NOT pending). `readyCount`
  unchanged (`isReady` count). TDD: regression tests for pending-vs-problem.

### Unit 2 (Core) — decouple boss reachability from outward verdict
- Rename `HarnessBossReachability.bundleIsReady` → `bundleIsInstalled`; key it on the boss
  entry's CONFIG status (`status == .ready`), NOT live `isReady`. `bossReachability()` builder
  passes `bossEntry?.status == .ready`. Update `bundleText`. Update call sites/tests.
- Rewrite `testBossWithExpiredTokenIsNotReachable` + `testInFlightAgentIsNotReady` +
  `testConfigReadyWithoutAnyLiveCheckIsUnverifiedNotReady` to assert CORRECT behavior.
- ADD false-RED regression: healthy machine, boss verdict in flight → `.healthy` + reachable.

## Verify (every unit)
- `swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`
- `swift test  -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`
- `Scripts/check-coverage.sh` (Core 100% line+region; allowlist unchanged at 2)

## Completion gates
- [x] Boss reachability keys on config-installed status (`bundleIsInstalled` = `status == .ready`), not outward verdict.
- [x] `hasUnready` true ONLY for problem entries; pending (`.checking`/`.unverified`) agents don't escalate.
- [x] Launch-window healthy-but-mid-check boss → `.healthy`, reachable, no "not reachable".
- [x] Confirmed-expired boss → reachable (drivable) + `.authExpired` pill + `.attention`.
- [x] Wrong tests rewritten; false-RED regression added.
- [x] Strict build + strict suite 0 failures (2457, 1 skipped); Core 100% line+region; allowlist 2.

## Progress log
- 2026-06-22 16:47 Single commit (both units): Core `HarnessStatus.swift` —
  (1) added `isPending`/`isProblem` on `HarnessAgentEntry` (ready / pending / problem trichotomy)
  and rewired `HarnessAgentInventory.hasUnready` to `contains(where: \.isProblem)` so pending agents
  no longer escalate; `readyCount` (live `.working`) unchanged. (2) Renamed
  `HarnessBossReachability.bundleIsReady` → `bundleIsInstalled`, keyed on the boss entry's CONFIG
  status (`bossEntry?.status == .ready`) not its live `isReady`, so a config-installed + MCP-registered
  boss is reachable regardless of the outward verdict. Updated `bundleText`/`state`/App call site.
  Rewrote `testInFlightAgentIsNotReady`, `testBossWithExpiredTokenIsNotReachable`
  (→ `…IsReachableButAttention`), and corrected `testConfigReadyWithoutAnyLiveCheckIsUnverifiedNotReady`
  to assert the CORRECT (calm-not-blocked) behavior; kept their per-agent pill/`liveReadiness`
  assertions. Added `testHealthyBossMidCheckIsReachableAndHealthy` (end-to-end false-RED guard),
  `testPendingOnlyAgentsDoNotRaiseUnready`, `testProblemAgentsRaiseUnready`,
  `testReadyAgentIsNeitherPendingNorProblem`. Strict build clean; 2457 tests / 0 failures / 1 skipped;
  Core 100% line+region; allowlist still 2.
