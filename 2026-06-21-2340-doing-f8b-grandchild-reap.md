# F8b — grandchild reaping via own-process-group spawn + killpg

**Status:** done
**Execution Mode:** direct
**Branch:** `fix/f8b-grandchild-reap` (off F11b-merged main `d1223c1`)
**Planning:** `/tmp/f8b-design-spec.md`
**Artifacts:** `./2026-06-21-2340-doing-f8b-grandchild-reap/`
**Constraints:** strict TDD (red→green); commit on this branch; NO push/PR/merge; no Co-Authored-By / attribution; `git add` only files I change (ignore `SerpentGuide.ouro/`, `*-doing-*.md` leftovers).

## Reshaping insight
`ProcessWatchdog` is NOT on the worst grandchild-forker's path. `mcp-serve` (`BossAgentMCPClient.callTool` / `listToolNames`) spawns through its own `ProcessIOBox` with a child-only `kill` seam — never `ProcessWatchdog`. `detachedStart` never kills. So the headline node-grandchild-leak fix lands in **ProcessIOBox.forceKill + detachedStart**, not the ProcessWatchdog callers. F8b = a shared own-group spawn primitive + a pure policy, wired onto the two real forkers; ProcessWatchdog also gets a LATENT gated killpg arm.

## Build order (de-risking — do NOT reorder)

### U1 — `WatchdogEscalation.swift` (re-add pure policy; 100%) ✅
Re-add the pure F8-removed policy: `enum WatchdogSignal {none;terminate;killChild;killGroup}` + `nextSignal(elapsedSinceDeadline:graceSeconds:childInOwnGroup:)` (4 arms; killGroup IFF childInOwnGroup). Unit-test all 4 arms.
- **Acceptance:** `WatchdogEscalationTests` all 4 arms + killGroup-iff-own-group pin; pure 100% line+region.

### U2 — `SpawnInOwnGroup.swift` (own-group spawn primitive) ✅
`import Darwin`. `posix_spawn` + `POSIX_SPAWN_SETPGROUP` + `setpgroup(&attr,0)` + file_actions dup2 of the 3 fds. `static func spawn(executablePath:arguments:environment:stdio:) throws -> Spawned {pid}`. FACTOR argv/envp marshalling into a PURE 100%-tested helper so only the raw `posix_spawn` call + its `guard rc==0` are impure.
- **Acceptance:** pure marshalling 100%; integration: `/usr/bin/env true` own-group → `getpgid(pid)==pid`; `/bin/sh -c 'sleep 30 & wait'` own-group → `killpg(SIGKILL)` → BOTH shell AND sleep grandchild gone (THE grandchild-reap proof); error arm: absolute non-existent path → throws. Target: NO allowlist entry.

### U3 — Rewire the two mcp-serve spawns (RISKIEST) ✅
Replace `Process()`+`process.run()` in `callTool` + `listToolNames` with `SpawnInOwnGroup.spawn(...)`. Byte-identical: same exe (`/usr/bin/env`), argv (`["env","ouro"]+mcpServeArguments`), env (`TerminalEnvironment().valuesWithResolvedPath()`), stdio. Rewrite `ProcessIOBox` to hold pid + pipe FileHandles + seams (drop `Process`): `terminate()`→`kill(pid,SIGTERM)`; `forceKill()`→`nextSignal(...childInOwnGroup:true)`→`.killGroup`→`killpg(pid,SIGKILL)` via injectable `groupKiller` seam (keep `processKiller`); liveness via `kill(pid,0)==0` seam. FAIL-CLOSED: after spawn verify `getpgid(pid)==pid`; on mismatch treat as child-only + audit line.
- **Acceptance:** existing BossAgentMCPClient end-to-end tests stay green; ProcessIOBox seam tests (forceKill routes via groupKiller for own-group; liveness skip when reaped; fail-closed child-only path).

### U4 — `detachedStart` (DaemonLiveness) ✅
Spawn via `SpawnInOwnGroup` (`/dev/null` fds), discard pid. Fix the over-claiming "setsid-equivalent" doc comment. Update ProcessWatchdog "F8b … arrives" doc comments.
- **Acceptance:** detachedStart spawns via SpawnInOwnGroup; doc comments corrected.

### U5 — ProcessWatchdog latent gated arm ✅
`escalateTermination` gains `childInOwnGroup:Bool=false` + `groupSignalDeliverer:@Sendable(pid_t,Int32)->Void={killpg($0,$1)}`; post-grace `switch nextSignal(...){case .killGroup: groupSignalDeliverer(pid,SIGKILL); default: signalDeliverer(pid,SIGKILL)}`. All 8 callers default `false`. INVERT the F8 `testProcessWatchdogNeverGroupReaps` pin → assert killpg arm GATED on `.killGroup`/`childInOwnGroup`.
- **Acceptance:** fake groupSignalDeliverer test (childInOwnGroup:true→killpg-not-kill; false→kill-not-killpg); inverted gate pin.

### U6 — Negative source-pins + wiring pins ✅
`SpawnOwnGroupWiringTests`: mcp-serve callTool+listToolNames spawn via SpawnInOwnGroup; ProcessIOBox.forceKill via groupKiller/.killGroup; detachedStart via SpawnInOwnGroup; NEGATIVE pins for the 6 finite runners (+ ps listers) NOT referencing `SpawnInOwnGroup`/`killpg`/own-group.

## Completion Criteria
- [x] `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` green — 2364 tests, 1 skipped, 0 failures (incl. SpawnInOwnGroup grandchild-reap integration test)
- [x] `Scripts/check-coverage.sh` PASS, Core 100% line+region — SpawnInOwnGroup needs NO allowlist; the only F8b allowlist addition is `ProcessWatchdog.swift 1 1` (the structurally-dead LATENT default killpg, documented; BossAgentMCPClient region budget LOWERED 3→2). The posix_spawn error region IS takeable (ENOENT test), so no `SpawnInOwnGroup.swift` fallback was needed.
- [x] Strict build clean (`swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`)
- [x] mcp-serve marshalling provably byte-identical to prior `Process()` (same `/usr/bin/env`, argv `["env","ouro"]+mcpServeArguments`, env `valuesWithResolvedPath()`, stdio pipe fds; argv[0] `env` vs `/usr/bin/env` is ignored by env — the command env runs is identical; pinned by SpawnOwnGroupWiringTests + proven live-equivalent by 35 mock-ouro-on-PATH e2e tests passing through the new path)
- [x] Single-flag invariant + fail-closed `getpgid` wired (`makeProcessBox` sets `childInOwnGroup` from `getpgid(spawned.pid)==spawned.pid`; the SAME flag gates forceKill's `.killGroup`)

## Operator follow-up (queued — needs the running app, computer-use off)
The MECHANISM is integration-proven (grandchild-reap test) and the marshalling fidelity is established by reasoning + the 35 e2e tests. The LIVE confirmation — a real boss conversation through mcp-serve + a `ps` check for orphaned `node` after a timeout/forceKill — requires launching the app and is QUEUED for the operator per spec §6 risk-5 / merge-gating note.

## Progress log
- 2026-06-21 23:40 Doc created; spec + all source/test files read; build order locked.
- 2026-06-21 23:42 U1 complete (1aad1f4): WatchdogEscalation re-added, 5 tests green, pure.
- 2026-06-21 23:46 U2 complete (dd2b97e): SpawnInOwnGroup primitive; 7 tests incl. getpgid==pid + grandchild-reap proof + ENOENT error arm; 100% line+region NO allowlist.
- 2026-06-22 00:05 U3 complete (6525870): mcp-serve callTool+listToolNames rewired to SpawnInOwnGroup (byte-identical /usr/bin/env+argv+env+stdio); ProcessIOBox now pid+pipes+seams, forceKill→killpg via WatchdogEscalation policy, fail-closed getpgid via pure ownGroupVerification; all 35 BossAgentMCPClient e2e tests + 13 ProcessIOBox tests green; coverage gate PASS, NO new allowlist (BossAgentMCPClient region budget LOWERED 3→2).
- 2026-06-22 00:09 U4 complete (c57217e): detachedStart spawns via SpawnInOwnGroup (own group, /dev/null stdio), pid discarded; over-claiming setsid-equivalent doc fixed; DaemonLiveness 100%.
- 2026-06-22 00:21 U5 complete (c209170): ProcessWatchdog gained latent gated killpg arm (childInOwnGroup default false + groupSignalDeliverer routed via nextSignal); F8 never-group-reap pin INVERTED → asserts killpg gated on .killGroup/childInOwnGroup; 1-line documented allowlist for the structurally-dead latent default killpg (real killpg proven elsewhere). Coverage gate PASS.
- 2026-06-22 00:24 U6 complete (39ce8a1): SpawnOwnGroupWiringTests — positive pins (mcp-serve 2 paths + detachedStart via SpawnInOwnGroup, marshalling byte-identical, forceKill→groupKiller on .killGroup, fail-closed getpgid, ProcessIOBox holds pid not Process); negative pins (6 finite runners + Core/MCP/App ps listers don't reference SpawnInOwnGroup/killpg/SETPGROUP/childInOwnGroup). 6 tests green.
- 2026-06-22 00:25 ALL GATES PASS. Gate 1 (impl coverage): all 6 units committed + match spec. Gate 2: strict full suite 2364 green + strict build clean. Gate 3 (PR review): marshalling byte-identical to prior Process(); single-flag invariant + fail-closed getpgid wired; all spec locked decisions met. Gate 4: finalized. Status → done. NO push/PR/merge per task constraints.
