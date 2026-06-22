# Doing: F11a — screen-lifecycle (terminal leak + startup reaper + start-race)

Planning: /tmp/f11-design-spec.md (F11a = PR1, defects 1+2 only; F11b is a SEPARATE later unit)
Execution Mode: direct
Branch: fix/f11a-screen-lifecycle (NO push/PR/merge)
Artifacts: ./f11a-screen-lifecycle/

## Scope
Defect 1: terminal leak on delete/archive + startup reaper.
Defect 2: start() races fire-and-forget quit vs immediate -D -RR.
Do NOT touch the action queue / applyBossAction (that is F11b).

## Units

- ✅ Unit 1a: ScreenSessionReaperTests (Core, RED) — orphan; KNOWN-id no-kill; empty live; known-no-live; mixed; quitArguments live vs nil; name round-trip.
- ✅ Unit 1b: ScreenSessionReaper.swift (Core, GREEN, 100%) — orphanedSessionNames (FORWARD derivation) + quitArguments(forEntryId:liveSessionNames:).
- ✅ Unit 2a: StartSequencerTests (Core, RED) — hasActive:true → quitThenAwait(name); false → launchImmediately; round-trip.
- ✅ Unit 2b: StartSequencer.swift (Core, GREEN, 100%) — StartSequenceStep enum + step(forEntryId:hasActiveSessionOnSocket:).
- ✅ Unit 3a: TerminalLeakReaperWiringTests (App source-pins, RED).
- ✅ Unit 3b: App wiring Defect 1 (GREEN) — spawnScreenQuit, quitPersistentScreenIfNeeded, reapOrphanedScreenSessions, load-success flag, delete/archive calls, startup ordering.
- ✅ Unit 4a: StartSequenceAwaitWiringTests (App source-pins, RED).
- ✅ Unit 4b: App wiring Defect 2 (GREEN) — terminatePersistentSessionAwaiting (single-shot continuation), async start(), launch/recover await.

## Completion Criteria
- [x] swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete green (2314 tests, 0 failures)
- [x] Scripts/check-coverage.sh PASS (Core 100% line+region; ScreenSessionReaper 12/12+5/5, StartSequencer 7/7+4/4; no new allowlist)
- [x] Strict build clean
- [x] Reaper runs AFTER refreshLiveScreenSessions + AFTER state-load, gated on load-success flag (not just knownEntryIds.isEmpty)
- [x] await-quit single-shot resume from BOTH terminationHandler AND watchdog (lock-backed SingleShotContinuation)
- [x] app-exit / terminate(_:) still use non-awaiting terminate()

## Progress Log
- 2026-06-21 22:19 Unit 1a/1b complete: ScreenSessionReaper Core seam (forward-derived orphan set + quitArguments), 8 tests green.
- 2026-06-21 22:21 Unit 2a/2b complete: StartSequencer Core seam (quitThenAwait/launchImmediately), 3 tests green.
- 2026-06-21 22:26 Unit 3a/3b complete: Defect 1 App wiring (quit on delete/archive, startup reaper, stateLoadSucceeded gate, shared spawnScreenQuit). 8 source-pins green; strict build clean.
- 2026-06-21 22:34 Unit 4a/4b complete: Defect 2 App wiring (async start consulting StartSequencer; terminatePersistentSessionAwaiting with lock-backed single-shot continuation resumed from terminationHandler+watchdog; launch/recover route through await start; app-exit/terminate(_:) stay non-awaiting). 11 source-pins green.
- 2026-06-21 22:35 Gates: full strict suite 2314/0; coverage PASS Core 100% (new files 100%, no new allowlist); strict build clean.
