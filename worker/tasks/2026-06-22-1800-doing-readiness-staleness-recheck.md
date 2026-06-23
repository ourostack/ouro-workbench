# Doing: Readiness staleness re-check (scene-phase + periodic backstop)

**Branch:** `fix/readiness-staleness-recheck` (off `main` @ `4cafba1`)
**Execution Mode:** direct
**Status:** in-progress
**Planning:** (inline design — embedded in task prompt, locked)
**Artifacts:** ./2026-06-22-1800-doing-readiness-staleness-recheck/

## Context

PRs #261/#262/#264 made agent readiness honest by overlaying a live `ouro check`
outward verdict. `WorkbenchViewModel.refreshAgentOutwardReadiness()`
(`OuroWorkbenchApp.swift:15173`) runs at the end of `refreshOuroAgents()`
(`:12298-12305`), so it fires on launch + the ~20 navigation/action triggers.

**The gap:** when the app sits FOCUSED + IDLE on one view for a long time
(daily-driver-left-open), nothing re-checks. A provider token that expires
mid-session leaves a STALE "ready" pill until the user manually navigates/refreshes.
There is NO scene-phase / app-became-active re-check and NO periodic re-check.
Add both, debounced so they never hammer or double-fire.

## Locked Decisions

- New pure Core policy `AgentReadinessRefreshPolicy.shouldRefresh(lastCheckedAt:now:staleAfter:)`:
  `lastCheckedAt == nil` → true; else `now.timeIntervalSince(lastCheckedAt) >= staleAfter` → true; else false.
  Negative/clock-skew (now < lastCheckedAt) → false. Pure, caller injects `now`. 100% line+region.
- `@Published private(set) var lastOutwardReadinessCheckAt: Date?` on the viewmodel, set to `Date()`
  at the START of `refreshAgentOutwardReadiness()` (before kicking the TaskGroup) — records freshness
  AND debounces concurrent triggers.
- `refreshOutwardReadinessIfStale(now:staleAfter:)` consults the policy and only calls
  `refreshAgentOutwardReadiness()` when stale.
- `WorkbenchRootView`: `@Environment(\.scenePhase)` + `.onChange(of: scenePhase)` calling
  `refreshOutwardReadinessIfStale(staleAfter: 60)` on `.active`; a separate periodic `.task {}`
  loop (`Task.sleep` 300s) calling `refreshOutwardReadinessIfStale(staleAfter: 300)`.
- Intervals: **60s** on-active debounce, **300s** periodic backstop.

## Constraints

- Untracked `SerpentGuide.ouro/` — DO NOT stage.
- Coverage allowlist unchanged at its 2 entries (BossAgentMCPClient.swift, SessionActivityReader.swift).
- Build/test with `-Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`.
- No Co-Authored-By / AI attribution. Commit per unit, push. DO NOT merge/PR.
- Debounce must prevent double-fire across scene-phase + periodic paths.

## Units

### ⬜ Unit 1 — Core debounce policy (pure, 100% line+region)
- **1a (test):** `Tests/OuroWorkbenchCoreTests/AgentReadinessRefreshPolicyTests.swift` —
  nil→true; fresh (elapsed < staleAfter)→false; exactly staleAfter→true; well past→true;
  negative/clock-skew (now < lastCheckedAt)→false. Must FAIL (red).
- **1b (impl):** `Sources/OuroWorkbenchCore/AgentReadinessRefreshPolicy.swift`. Tests PASS (green).
  Build clean. Coverage 100% line+region; allowlist still 2.

### ⬜ Unit 2 — App wiring + source-pin test
- Add `lastOutwardReadinessCheckAt` `@Published private(set)`; set at start of
  `refreshAgentOutwardReadiness()`.
- Add `refreshOutwardReadinessIfStale(now:staleAfter:)` consulting `AgentReadinessRefreshPolicy.shouldRefresh`.
- `WorkbenchRootView`: scenePhase `.onChange` → `refreshOutwardReadinessIfStale(staleAfter: 60)` on `.active`;
  separate periodic `.task {}` loop → `refreshOutwardReadinessIfStale(staleAfter: 300)`.
- Source-pin test `Tests/OuroWorkbenchCoreTests/ReadinessStalenessRefreshWiringTests.swift`.
- Build + full test suite green with warnings-as-errors + strict concurrency.

## Completion Criteria

- [ ] Unit 1: pure policy with the 5 specified cases, 100% line+region, allowlist still 2.
- [ ] Unit 2: viewmodel timestamp + IfStale method + root-view scene-phase + periodic wiring.
- [ ] Source-pin test asserts all four wiring facts.
- [ ] `swift build` + `swift test` clean with `-warnings-as-errors -strict-concurrency=complete`.
- [ ] `Scripts/check-coverage.sh` passes (Core 100% line+region; allowlist 2).
- [ ] Debounce confirmed: no double-fire across scene-phase + periodic; in-flight refresh not duplicated.
- [ ] Committed + pushed per unit. NOT merged/PR'd.

## Progress Log

- 2026-06-22 18:00 Doc created. Branch `fix/readiness-staleness-recheck` off main (4cafba1).
