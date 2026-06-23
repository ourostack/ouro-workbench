# Doing: Boss MCP client process-reliability fixes

- **Status:** done
- **Execution Mode:** direct
- **Branch:** `fix/boss-client-process-reliability` (off `main` @ dd852d5)
- **Worktree:** `/Users/microsoft/code/ouro-workbench-boss-reliability` (ISOLATED)
- **Scope:** `Sources/OuroWorkbenchCore/BossAgentMCPClient.swift`, `Sources/OuroWorkbenchCore/DaemonLiveness.swift` (+ tests)
- **Constraint:** LIVE boss `mcp-serve` spawn path. Keep spawn/argv/env/stdio marshalling, own-group (F8b) spawn, and response-classification BYTE-IDENTICAL. Only add: pipe-close + read-unblock-on-watchdog + (optional) detachedStart doc/track.
- **No merge / no PR.** Commit per fix, push.

## Re-anchoring against actual `main` (anchors in the prompt are stale)

The prompt's line refs (`:114-126`, `:303-330`, `:367-382`) were written against an OLDER
revision (the `fix/onboarding-audit` branch's `BossAgentMCPClient.swift`). `main` (@ dd852d5)
is materially ahead — it already has the F8b own-group `posix_spawn` (`SpawnInOwnGroup`),
the per-turn `reaper` (zombie-leak fix), and a fully-refactored `detachedStart`. Re-verified
by symbol/grep at HEAD:

- **Spawn site:** ONE shared helper `spawnMCPServe(agentName:)` feeds BOTH `callTool` AND
  `listToolNames`. It builds 3 `Pipe()`s; after spawn it closes the child-side ends it handed
  off (`stdinPipe.read`, `stdoutPipe.write`, `stderrPipe.write`) but the `ProcessIOBox` keeps
  `stdoutPipe.fileHandleForReading` + `stderrPipe.fileHandleForReading` — these READ handles are
  NEVER closed. → FIX 1 is REAL.
- **Watchdog:** `readResponse` / `readResponseLine` each run a 2-task group; the timeout task
  does `terminate()` + `forceKill()` then throws `.timeout`. It does NOT close the read handle,
  so a pathological child that writes nothing + holds its write end open can park
  `stdout.availableData` past the SIGKILL. → FIX 2 is REAL.
- **detachedStart:** ALREADY tracks + reaps. `detachedStartSync(spawn:reap:)` returns the
  launcher pid from `SpawnInOwnGroup.spawn` and reaps it via a detached `waitpid` thread. The
  prompt's FIX 3 ("no waitUntilExit + no PID tracking") describes the OLD code. → FIX 3 already
  satisfied on main (the HIGHER-fidelity "track the PID" option). No code change needed; a
  one-line doc affirmation only.

## Completion Criteria

- [x] FIX 1: stdout/stderr READ handles closed on BOTH success + error/timeout paths, AFTER the
      response read completes; closing happens via an idempotent seam on `ProcessIOBox`.
- [x] FIX 2: the read carries its own bounded poll(2) deadline so a no-output-hang child does not
      park the worker past the timeout budget. (Mechanism pivot — see note below: closing the read
      fd under a parked `availableData` ABORTS the process via NSException, so the prompt's
      sanctioned "bounded deadline + abandon" alternative is used instead of fd-close-to-unblock.)
- [x] FIX 3: confirmed already satisfied on main (detachedStart tracks + reaps launcher pid);
      doc affirmation only.
- [x] Spawn executable/argv/env/stdio marshalling, own-group spawn, response-classification
      UNCHANGED (byte-identical) — verified by diff (only comments mention those keywords).
- [x] `swift build` + `swift test` clean with `-Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`.
- [x] `scripts/check-coverage.sh` passes; allowlist UNCHANGED at exactly 2 entries.
- [x] Commit per fix; pushed. No SerpentGuide.ouro staged. No AI attribution.

### FIX 2 mechanism pivot (important)
The prompt offered TWO robust options: (a) close the read fd on watchdog fire to unblock a parked
`availableData`, OR (b) "read with a bounded deadline and abandon." I implemented (a) first and it
FAILED hard: `FileHandle.availableData` raises `NSFileHandleOperationException` (→ `abort()`, signal
6) when its fd is closed mid-read — both `FileHandle.close()` AND a raw `Darwin.close(fd)` trigger it
(verified by a crashing test). So (b) is the safe path: each blocking `availableData` is gated by a
`poll(2)` on the stdout fd with the remaining budget. A well-behaved child is readable immediately
(happy path byte-identical); a wedged child hits the deadline and the read returns `.timeout`. The
fd is only ever closed by `stop()` AFTER the read is complete (FIX 1), never under a parked read.

---

## Units

### Unit 1a — FIX 1 tests (RED): read handles closed on success + error paths ✅
- **What:** Add a `closeReadHandles()` seam to `ProcessIOBox` (to be implemented in 1b) and tests
  that pin: after `stop()`, the stdout/stderr read fds are closed (no leak); and an integration
  test that spawns N children through the client path and asserts the process's open-fd count does
  NOT grow. Mirror the existing `ProcessIOBoxTests` / `BossAgentMCPClientTests` integration style.
- **Output:** failing tests in `ProcessIOBoxTests.swift` + `BossAgentMCPClientTests.swift`.
- **Acceptance:** tests compile and FAIL (no `closeReadHandles` / fds still open) before 1b.

### Unit 1b — FIX 1 impl (GREEN): close read handles ✅
- **What:** Add idempotent `closeReadHandles()` to `ProcessIOBox`; call it from `stop()` AFTER the
  reap (read is already complete by then). `callTool`/`listToolNames` already call `stop()` on both
  success and error paths, so this covers both.
- **Acceptance:** 1a tests pass; spawn/argv/env/classification untouched; build clean.

### Unit 2a — FIX 2 tests (RED): no-output child does not park past the watchdog ✅
- **What:** Integration test — a mock `ouro` that reads its two requests then writes NOTHING and
  hangs (holding stdout open). With a short timeout, the client must return `.timeout` within a
  bounded budget (not park). Plus a unit pin that the watchdog path closes the read handle.
- **Acceptance:** test FAILS or hangs without the unblock (demonstrated), passes after 2b.

### Unit 2b — FIX 2 impl (GREEN): unblock the read on watchdog fire ✅
- **What:** In the watchdog task of `readResponse` + `readResponseLine`, after `terminate()` +
  `forceKill()`, call `processBox.closeReadHandles()` to unblock a parked `availableData`. Order:
  SIGKILL the process, THEN close the read handle, then the read returns and the group unwinds.
- **Acceptance:** 2a tests pass; happy-path read behavior identical; build clean.

### Unit 3 — FIX 3 doc affirmation ✅
- **What:** Confirm `detachedStart` already tracks + reaps the launcher pid on main. Add a brief
  affirming sentence to the doc comment (no behavior change). LOW / optional.
- **Acceptance:** build clean; no behavior change.

### Unit 4 — Verify gates ✅
- **What:** Full `swift build` + `swift test` with warnings-as-errors + strict concurrency;
  `scripts/check-coverage.sh`; allowlist still exactly 2 entries.
- **Acceptance:** 0 failures, coverage gate green, allowlist unchanged.

## Progress Log

- 2026-06-23 11:34 Unit 1a complete: RED tests — `closeReadHandles()` referenced (compile-fails,
  proving new behavior) + `testStopClosesTheStdoutAndStderrReadHandles` (fds open before stop) +
  `testRepeatedCallsDoNotLeakPipeFileDescriptors` integration test (open-fd count flat across 25 turns).
- 2026-06-23 11:38 Unit 1b complete: added idempotent `closeReadHandles()` to `ProcessIOBox`,
  called from `stop()` after the reap. FIX 1 tests green (17 incl. integration); build clean with
  warnings-as-errors + strict-concurrency=complete. Spawn/argv/env/classification untouched. Pushed.
- 2026-06-23 11:48 Unit 2a/2b complete (FIX 2): demonstrated RED by an integration test that PARKED
  25s on un-fixed code (escaped-grandchild holds stdout past killpg). First tried close-to-unblock
  → it ABORTS (NSFileHandleOperationException, signal 6) under a parked `availableData`; pivoted to
  the prompt-sanctioned bounded poll(2) deadline. The read now gates each `availableData` on a poll
  with the remaining budget → returns `.timeout` instead of parking. Hardened the FIX-1 close to be
  recycle-safe (dup'd box-owned read fds). Watchdog process-kill + F8b reaping unchanged.
- 2026-06-23 11:50 Unit 3 complete (FIX 3): detachedStart already tracks + reaps the launcher pid on
  main (the higher-fidelity option); added a process-reliability doc note. No behaviour change.
- 2026-06-23 11:58 Unit 4 complete: refactored the poll wait into pure value-tested seams
  (`pollTimeoutMillis`/`pollOutcome` + single-poll `pollReadable`) so the read loop's EINTR `.retry`
  is covered via an injected `pollProvider`, with NO new structurally-unreachable brace. Full suite
  0 failures with warnings-as-errors + strict-concurrency=complete; `scripts/check-coverage.sh`
  PASSES; allowlist UNCHANGED at exactly 2 entries (BossAgentMCPClient.swift back to its documented
  1-line / 2-region structural exclusion). Spawn marshalling / own-group / classification verified
  byte-identical by diff. All gates passed.
