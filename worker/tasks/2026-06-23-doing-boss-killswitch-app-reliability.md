# Doing: Boss Kill-Switch + App Reliability fixes

- **Branch:** `fix/boss-killswitch-app-reliability` (off `origin/main` @ a6516ec)
- **Worktree:** `/Users/microsoft/code/ouro-workbench-killswitch` (ISOLATED) — `git -C <worktree>` for all git
- **Execution Mode:** direct
- **Target file:** `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` (anchors re-verified by symbol/grep)
- **New pure seams:** `Sources/OuroWorkbenchCore/BossAutonomyGating.swift` (coverage-gated, 100%)
- **Source-pin tests:** `Tests/OuroWorkbenchCoreTests/BossAutonomyKillSwitchWiringTests.swift`
- **Constraints:** strict TDD; commit per fix; push branch; DO NOT merge/PR. No Co-Authored-By / AI attribution. No `SerpentGuide.ouro/` staged. Allowlist unchanged at 2.
- **Verify:** `swift build`/`swift test` with `-Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`; `Scripts/check-coverage.sh` (100%, allowlist unchanged at 2). 0 failures.

## Status: in progress

## Completion Criteria
- [x] FIX1: pump gates drain+apply on `bossWatchIsEnabled`; queued requests HELD on disk when paused, applied on resume; ON-path unchanged
- [ ] FIX2: screen terminators SIGKILL after the timeout+terminate() at each call site
- [ ] FIX3: a single check-in applies actions + records decisions then save()s ONCE; suppression guards respected
- [ ] FIX4: boss-watch loop doesn't wake-spin every 60s while Watch is OFF (start/stop driven by setBossWatchEnabled)
- [ ] New Core seam logic 100% line+region; allowlist unchanged at 2
- [ ] `swift build` + `swift test` strict flags clean (0 failures, 0 warnings)
- [ ] `Scripts/check-coverage.sh` passes
- [ ] One commit per fix (4), pushed; no PR/merge

---

## Unit 1 — FIX1 (HIGH): "Pause Boss Watch" true kill-switch ✅

**What:** Gate `runExternalActionPump()`'s drain+apply step on `bossWatchIsEnabled`. While paused, the pump must NOT drain+apply queued actions (held on disk, not lost). Resuming applies the held queue. Extract a pure `shouldApplyQueuedActions(bossWatchEnabled:)` seam in Core.

**Anchors (re-verified):**
- `func runExternalActionPump() async` @ ~16621 — the unconditional `.task` drain loop (launched @ ~641)
- `@Published var bossWatchIsEnabled` @ ~10528
- `func setBossWatchEnabled(_:)` @ ~13735 (resume must re-apply held queue)

**Tests (Xa):**
- Core: `BossAutonomyGating.shouldApplyQueuedActions(bossWatchEnabled:)` — true iff enabled (exhaustive: true→true, false→false).
- Source-pin: pump's drain loop checks `bossWatchIsEnabled` / `shouldApplyQueuedActions` BEFORE draining/applying; when off it skips applying (does NOT drain into processing/ — leaves requests queued); ON path unchanged.

**Output:** Pure seam + gated pump. Queued requests HELD on disk while paused.
**Acceptance:** Paused → no apply, queue intact on disk. Resumed → held queue applies. ON → unchanged. Manual one-shot Check-In unaffected (separate path).

## Unit 2 — FIX2 (MED): screen-terminate SIGKILL backstop ⬜

**What:** After each screen terminator's `waitUntilExit` timeout fires + `process.terminate()`, add `kill(process.processIdentifier, SIGKILL)` (mirror BossAgentMCPClient forceKill / WorkbenchVisibility pattern).

**Anchors (re-verified — 3 screen call sites, timeout→terminate() with no SIGKILL):**
- `spawnScreenQuit(...)` @ ~16780/16784
- `listLiveScreenSessionNames()` @ ~16894/16898
- `persistentSessionIsListed(_:)` @ ~19800/19804

**Tests (Xa):** Source-pin: each of the 3 screen terminators has `kill(process.processIdentifier, SIGKILL)` after its `.timedOut` `terminate()`.
**Output:** SIGKILL backstop at each call site.
**Acceptance:** A SIGTERM-ignoring screen process is force-killed.

## Unit 3 — FIX3 (MED): single check-in → save() once ⬜

**What:** Restructure so one check-in applies actions + records decisions, then `save()` ONCE at the end. Add a batched-save suppression seam so the per-action `recordActionLog` saves + `recordBossDecisions` save fold into a single trailing save. Respect `isLoadingState`/`isResettingToFirstRun` guards.

**Anchors (re-verified):**
- success path @ ~16365: `applyBossActions(from:)` then `recordBossDecisions(from:)`
- `recordActionLog(...)` @ ~19117 ends with `save()`
- `recordBossDecisions(...)` @ ~16411, `if changed > 0 { save() }` @ ~16494
- `private func save() -> Bool` @ ~20102 (guards)

**Tests (Xa):**
- Source-pin: the apply+record region is wrapped in a single-save batch (per-action `save()`s suppressed) with one trailing `save()`; guards intact.
**Output:** Atomic action-log + decision/inbox persistence per check-in.
**Acceptance:** Executed actions + their decision rows persist in the SAME save(); zero-change batch still saves the action rows.

## Unit 4 — FIX4 (LOW): boss-watch loop doesn't wake-spin while OFF ⬜

**What:** Drive the loop start/stop from `setBossWatchEnabled` (start on enable, cancel on disable) so the loop doesn't wake every 60s just to `continue` while OFF.

**Anchors (re-verified):**
- `func runBossWatchLoop()` @ ~13759 (`sleep` then `guard bossWatchIsEnabled else { continue }`)
- launched as unconditional `.task` @ ~643
- `func setBossWatchEnabled(_:)` @ ~13735

**Tests (Xa):** Source-pin: the loop is started/cancelled by `setBossWatchEnabled` (held task handle); the loop no longer has the wake-then-`continue`-while-off busy pattern.
**Output:** No idle wakeups while Watch OFF; re-enable resumes the loop.
**Acceptance:** Loop runs only while enabled; re-enabling resumes it.

---

## Progress Log
- 2026-06-23 10:46 Doc created; worktree + branch set up off origin/main (a6516ec); all anchors re-verified by grep.
- 2026-06-23 11:35 Unit 1 (FIX1) complete: `BossAutonomyGating.shouldApplyQueuedActions` seam (Core) + pump loop gates `drainExternalActionRequests()` on `bossWatchIsEnabled` BEFORE draining, so paused requests stay HELD in queue dir (drain moves to processing/; skipping the drain is what holds them). 4 FIX1 tests green; strict build clean. Commit b7ba4d5.
