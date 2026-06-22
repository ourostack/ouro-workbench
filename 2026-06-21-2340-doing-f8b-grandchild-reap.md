# F8b — grandchild reaping via own-process-group spawn + killpg

**Status:** in-progress
**Execution Mode:** direct
**Branch:** `fix/f8b-grandchild-reap` (off F11b-merged main `d1223c1`)
**Planning:** `/tmp/f8b-design-spec.md`
**Artifacts:** `./2026-06-21-2340-doing-f8b-grandchild-reap/`
**Constraints:** strict TDD (red→green); commit on this branch; NO push/PR/merge; no Co-Authored-By / attribution; `git add` only files I change (ignore `SerpentGuide.ouro/`, `*-doing-*.md` leftovers).

## Reshaping insight
`ProcessWatchdog` is NOT on the worst grandchild-forker's path. `mcp-serve` (`BossAgentMCPClient.callTool` / `listToolNames`) spawns through its own `ProcessIOBox` with a child-only `kill` seam — never `ProcessWatchdog`. `detachedStart` never kills. So the headline node-grandchild-leak fix lands in **ProcessIOBox.forceKill + detachedStart**, not the ProcessWatchdog callers. F8b = a shared own-group spawn primitive + a pure policy, wired onto the two real forkers; ProcessWatchdog also gets a LATENT gated killpg arm.

## Build order (de-risking — do NOT reorder)

### U1 — `WatchdogEscalation.swift` (re-add pure policy; 100%) ⬜
Re-add the pure F8-removed policy: `enum WatchdogSignal {none;terminate;killChild;killGroup}` + `nextSignal(elapsedSinceDeadline:graceSeconds:childInOwnGroup:)` (4 arms; killGroup IFF childInOwnGroup). Unit-test all 4 arms.
- **Acceptance:** `WatchdogEscalationTests` all 4 arms + killGroup-iff-own-group pin; pure 100% line+region.

### U2 — `SpawnInOwnGroup.swift` (own-group spawn primitive) ⬜
`import Darwin`. `posix_spawn` + `POSIX_SPAWN_SETPGROUP` + `setpgroup(&attr,0)` + file_actions dup2 of the 3 fds. `static func spawn(executablePath:arguments:environment:stdio:) throws -> Spawned {pid}`. FACTOR argv/envp marshalling into a PURE 100%-tested helper so only the raw `posix_spawn` call + its `guard rc==0` are impure.
- **Acceptance:** pure marshalling 100%; integration: `/usr/bin/env true` own-group → `getpgid(pid)==pid`; `/bin/sh -c 'sleep 30 & wait'` own-group → `killpg(SIGKILL)` → BOTH shell AND sleep grandchild gone (THE grandchild-reap proof); error arm: absolute non-existent path → throws. Target: NO allowlist entry.

### U3 — Rewire the two mcp-serve spawns (RISKIEST) ⬜
Replace `Process()`+`process.run()` in `callTool` + `listToolNames` with `SpawnInOwnGroup.spawn(...)`. Byte-identical: same exe (`/usr/bin/env`), argv (`["env","ouro"]+mcpServeArguments`), env (`TerminalEnvironment().valuesWithResolvedPath()`), stdio. Rewrite `ProcessIOBox` to hold pid + pipe FileHandles + seams (drop `Process`): `terminate()`→`kill(pid,SIGTERM)`; `forceKill()`→`nextSignal(...childInOwnGroup:true)`→`.killGroup`→`killpg(pid,SIGKILL)` via injectable `groupKiller` seam (keep `processKiller`); liveness via `kill(pid,0)==0` seam. FAIL-CLOSED: after spawn verify `getpgid(pid)==pid`; on mismatch treat as child-only + audit line.
- **Acceptance:** existing BossAgentMCPClient end-to-end tests stay green; ProcessIOBox seam tests (forceKill routes via groupKiller for own-group; liveness skip when reaped; fail-closed child-only path).

### U4 — `detachedStart` (DaemonLiveness) ⬜
Spawn via `SpawnInOwnGroup` (`/dev/null` fds), discard pid. Fix the over-claiming "setsid-equivalent" doc comment. Update ProcessWatchdog "F8b … arrives" doc comments.
- **Acceptance:** detachedStart spawns via SpawnInOwnGroup; doc comments corrected.

### U5 — ProcessWatchdog latent gated arm ⬜
`escalateTermination` gains `childInOwnGroup:Bool=false` + `groupSignalDeliverer:@Sendable(pid_t,Int32)->Void={killpg($0,$1)}`; post-grace `switch nextSignal(...){case .killGroup: groupSignalDeliverer(pid,SIGKILL); default: signalDeliverer(pid,SIGKILL)}`. All 8 callers default `false`. INVERT the F8 `testProcessWatchdogNeverGroupReaps` pin → assert killpg arm GATED on `.killGroup`/`childInOwnGroup`.
- **Acceptance:** fake groupSignalDeliverer test (childInOwnGroup:true→killpg-not-kill; false→kill-not-killpg); inverted gate pin.

### U6 — Negative source-pins + wiring pins ⬜
`SpawnOwnGroupWiringTests`: mcp-serve callTool+listToolNames spawn via SpawnInOwnGroup; ProcessIOBox.forceKill via groupKiller/.killGroup; detachedStart via SpawnInOwnGroup; NEGATIVE pins for the 6 finite runners (+ ps listers) NOT referencing `SpawnInOwnGroup`/`killpg`/own-group.

## Completion Criteria
- [ ] `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` green (incl. grandchild-reap integration test)
- [ ] `Scripts/check-coverage.sh` PASS, Core 100% line+region, NO new allowlist (or single documented `SpawnInOwnGroup.swift 0 1` fallback only if posix_spawn error region un-takeable)
- [ ] Strict build clean
- [ ] mcp-serve marshalling provably byte-identical to prior `Process()`
- [ ] Single-flag invariant + fail-closed `getpgid` wired

## Progress log
- 2026-06-21 23:40 Doc created; spec + all source/test files read; build order locked.
