# Doing: Boss MCP client process-reliability fixes

- **Status:** in-progress
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

- [ ] FIX 1: stdout/stderr READ handles closed on BOTH success + error/timeout paths, AFTER the
      response read completes; closing happens via an idempotent seam on `ProcessIOBox`.
- [ ] FIX 2: on watchdog fire, the read is unblocked (read handle closed after SIGKILL) so a
      no-output-hang child does not park the worker past the timeout budget.
- [ ] FIX 3: confirmed already satisfied on main (detachedStart tracks + reaps launcher pid);
      doc affirmation only.
- [ ] Spawn executable/argv/env/stdio marshalling, own-group spawn, response-classification
      UNCHANGED (byte-identical).
- [ ] `swift build` + `swift test` clean with `-Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`.
- [ ] `scripts/check-coverage.sh` passes; allowlist UNCHANGED at exactly 2 entries.
- [ ] Commit per fix; pushed. No SerpentGuide.ouro staged. No AI attribution.

---

## Units

### Unit 1a — FIX 1 tests (RED): read handles closed on success + error paths ⬜
- **What:** Add a `closeReadHandles()` seam to `ProcessIOBox` (to be implemented in 1b) and tests
  that pin: after `stop()`, the stdout/stderr read fds are closed (no leak); and an integration
  test that spawns N children through the client path and asserts the process's open-fd count does
  NOT grow. Mirror the existing `ProcessIOBoxTests` / `BossAgentMCPClientTests` integration style.
- **Output:** failing tests in `ProcessIOBoxTests.swift` + `BossAgentMCPClientTests.swift`.
- **Acceptance:** tests compile and FAIL (no `closeReadHandles` / fds still open) before 1b.

### Unit 1b — FIX 1 impl (GREEN): close read handles ⬜
- **What:** Add idempotent `closeReadHandles()` to `ProcessIOBox`; call it from `stop()` AFTER the
  reap (read is already complete by then). `callTool`/`listToolNames` already call `stop()` on both
  success and error paths, so this covers both.
- **Acceptance:** 1a tests pass; spawn/argv/env/classification untouched; build clean.

### Unit 2a — FIX 2 tests (RED): no-output child does not park past the watchdog ⬜
- **What:** Integration test — a mock `ouro` that reads its two requests then writes NOTHING and
  hangs (holding stdout open). With a short timeout, the client must return `.timeout` within a
  bounded budget (not park). Plus a unit pin that the watchdog path closes the read handle.
- **Acceptance:** test FAILS or hangs without the unblock (demonstrated), passes after 2b.

### Unit 2b — FIX 2 impl (GREEN): unblock the read on watchdog fire ⬜
- **What:** In the watchdog task of `readResponse` + `readResponseLine`, after `terminate()` +
  `forceKill()`, call `processBox.closeReadHandles()` to unblock a parked `availableData`. Order:
  SIGKILL the process, THEN close the read handle, then the read returns and the group unwinds.
- **Acceptance:** 2a tests pass; happy-path read behavior identical; build clean.

### Unit 3 — FIX 3 doc affirmation ⬜
- **What:** Confirm `detachedStart` already tracks + reaps the launcher pid on main. Add a brief
  affirming sentence to the doc comment (no behavior change). LOW / optional.
- **Acceptance:** build clean; no behavior change.

### Unit 4 — Verify gates ⬜
- **What:** Full `swift build` + `swift test` with warnings-as-errors + strict concurrency;
  `scripts/check-coverage.sh`; allowlist still exactly 2 entries.
- **Acceptance:** 0 failures, coverage gate green, allowlist unchanged.

## Progress Log
