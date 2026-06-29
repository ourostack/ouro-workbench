# VM-GATE campaign — progress checkpoint

Driving `WorkbenchViewModel.swift` to its irreducible coverage floor, per-cluster PRs, full
autopilot (merge on CI-green, no per-cluster approval). Each region: invoked + effect-asserted +
mutation-verified; allowlist set to the CI-measured exact minimum (probe-then-set); scope-pure;
VERSION bump; flaky-region protocol applied.

## Landed clusters (all merged to main, CI-green)

| Cluster | PR | Version | What | VM allowlist after |
|---|---|---|---|---|
| (gate-wire + 1) | #357 | 0.1.188 | gate VM + `applyBossAction` full dispatch | 5505 / 1591 |
| 2 | #358 | 0.1.189 | `performCommand` (both overloads) dispatch | 5407 / 1542 |
| 3 | #360 | 0.1.191 | provider-config form + vault-onboarding flows | 5182 / 1532 |
| 4 | #361 | 0.1.192 | release-update / bug-report / support-diagnostics / recovery-drill | 5098 / 1514 |
| (flake-fix) | #364 | 0.1.193 | VM allowlist → STABLE MAX (absorb async oscillation; class-C) | **5102 / 1515** |
| 5 | #366 | 0.1.195 | markTerminated + applyAttentionSignal + exit-notification decision/throttle | **4916 / 1451** |
| 6 | #367 | 0.1.196 | deleteCustomSession/archive + revealLatestTranscript + requestStop/confirmStop + applySessionIdBackfills | **4799 / 1415** |
| 7 | #368 | 0.1.198 | start* onboarding handlers (verify/refresh/ensureDaemon/reportBug skip+ack arms) + completeOnboardingAction + completeFirstRunBootstrap | **4637 / 1392** |
| 8 | #371 | 0.1.199 | runBossWatchTick guard/no-wake + registerBossWatchFailure + applyExternalActionRequests + triggerEventDrivenBossCheckIn | **4552 / 1378** |
| 9 | #373 | 0.1.200 | BIG BATCH: commandPaletteItems (all cmd arms) + load (normal/first-run/lossy-salvage/quarantine) + startup reconcile/recover/auto-resume + reapOrphanedScreen + reclassify/backfill folds + prepareForTermination + stopAll + drainExternalActionRequests | **3906 / 1259** |
| 10 | #376 | 0.1.201 | onboarding guard tail: scan/reconstruction not-ready guards + repair/select/register-MCP skip guards | **3829 / 1247 local cap; tighten from CI log if lower** |

Cluster 5 result: CI residual 4912/1450 (190 lines / 65 regions driven OUT of 5102/1515); allowlist
set to STABLE MAX 4916/1451 (+4/+1 class-C oscillation tolerance, per the cluster-4 precedent).
Cluster 6 result: CI residual 4795/1414 (121 lines / 37 regions driven OUT of 4916/1451); allowlist
set to STABLE MAX 4799/1415. New seam: `quitPersistentScreenForEntry` (routes BOTH delete + archive;
its TerminalLeakReaperWiringTests source-pins were updated to the new marker — the
source-introspection-test caveat the ledger flagged). `applySessionIdBackfills` widened private→internal.
Cluster 7 result: CI residual 4633/1391 (166 lines / 24 regions driven OUT of 4799/1415); allowlist
set to STABLE MAX 4637/1392. Widened private→internal: startVerifyProvider/startRefreshProvider/
startEnsureDaemon/startReportBug/completeOnboardingAction/completeFirstRunBootstrap. The
BossActionLogPendingWiringTests `handlerBody` source-slicer was made `private`-agnostic (match `func
<name>(` + stop at the next private OR internal func) so the widen didn't break its source-pins.
Cluster 8 result: CI residual 4548/1377 (85 lines / 14 regions driven OUT of 4637/1392); allowlist
set to STABLE MAX 4552/1378. Widened private→internal: registerBossWatchFailure /
applyExternalActionRequests / triggerEventDrivenBossCheckIn (ReplayDedupWiringTests'
applyExternalActionRequests slicer made `private`-agnostic). runBossWatchTick already internal.

CADENCE CHANGE (cluster 9 onward, per coordinator): the prior per-tiny-cluster cadence had too much
CI/merge/conflict overhead at the ~250-decl tail scale. Switched to BIG BATCHES (~30-50 decls / a big
chunk of the residual per PR) so the whole tail lands in ~4-6 PRs. STRICT SERIALIZE: exactly ONE open
VM PR at a time (prior doers opened 2 concurrently → conflicts on WorkbenchViewModel.swift + allowlist
+ VERSION; do NOT). The #369 (old cluster 8) startup-reconcile PR was CLOSED by the coordinator as
superseded (its applyExternalActionRequests overlap landed in #371; its base was behind main's
allowlist). Cluster 9 re-drove the startup-reconcile/state-load area fresh + much larger.
Cluster 9 (BIG BATCH, startup / state-load / session lifecycle, v0.1.200, #373): 39 tests drive
commandPaletteItems (all conditional command arms present+absent), load() (normal / first-run-forced /
lossy-salvage `.salvageBeforeResave` / unreadable `.moved` quarantine — via seeded state files),
reconcileStartupAttentionWithLiveSessions, recoverEligibleSessionsOnStartup,
launchAutoResumeSessionsOnStartup, reapOrphanedScreenSessions (per-orphan quit seamed behind NEW
`spawnPersistentScreenQuit`; default routes to shared spawnScreenQuit, TerminalLeakReaper pin updated
+ default-routing pin added), reclassifyAttentionForFlushedRuns + backfillSessionIdsForFlushedRuns
(widened private→internal, SessionIdBackfill slicers made private-agnostic), prepareForTermination,
stopAllRunningSessions, drainExternalActionRequests. Carved: resetToFirstRun (NSApp.terminate +
relaunch subprocess), live `screen -ls` Process/Pipe/kill, the literal Process in the
spawnPersistentScreenQuit default closure, the async ps-backed backfill scan, load()'s `.moveFailed`
arm (store-internal, not seed-forceable). CI residual 3902/1257 (650 lines / 121 regions driven OUT
of 4552/1378; run 28356481057 — the PROBE 3856/1252 FAILED on both axes, so the gate printed the
exact count). Allowlist set to STABLE MAX 3906/1259 (+4 line / +2 region class-(C) buffer). The
#369→#372 startup-reconcile path (resurrected by a leftover prior-doer process as a 2nd concurrent
PR) was CLOSED by the coordinator as superseded — #373 drove its substantive scope + much more.

Cluster 10 (onboarding guard tail, v0.1.201, #376): drives the remaining synchronous onboarding
guards carried forward from the closed superseded startup-reconcile path: scanForOnboardingSessions re-entrancy and
not-ready returns, startBossReconstruction not-ready return, startRepairAgent missing-name return,
startSelectLane missing-payload return, and startRegisterWorkbenchMCP missing-name return. Local
baseline on origin/main measured 3913/1263 while GitHub CI's accepted #373 cap is 3906/1259. Two
branch-local coverage runs measured 3825/1247 and 3829/1238, so this branch starts with the
local-stable 3829/1247 cap and tightens from the PR Coverage log if GitHub reports a lower exact
residual.

SOURCE-INTROSPECTION CAVEAT (reconfirmed, clusters 6+7+8+9): BEFORE widening a `private func` for a
cluster, `grep -rln '<funcName>' Tests/` for a WiringTest that slices `private func <name>` — update
its slicer to a `private`-agnostic match in the SAME PR (else CI reds on Swift tests + Coverage).

NOTE (cluster 5): local full-suite coverage is NOT reliably runnable in this worktree env — the
pre-existing `ReportBugSheetInteractionTests` reveal/copy taps call
`NSWorkspace.activateFileViewerSelecting` / `NSPasteboard`, which BLOCK in headless macOS here
(NSServicesMenuHandler, no window server). So cluster 5 uses the campaign's documented
probe-then-set via the CI Coverage job (PR #366 carries a PROBE allowlist 4950/1490; read the exact
residual off CI, then set the stable max). New seams: `persistentSessionLister`,
`postExitNotification` (both prod byte-identical, @MainActor).

Start residual (scoping): 5892 lines / 1696 regions (44.0% line / 40.7% region).
Current (main): **3906 lines / 1259 regions** — the #373 STABLE MAX (CI exact 3902/1257 +4/+2
startup/async class-(C) tolerance). Cluster 10 branch-local cap: **3829 lines / 1247 regions** until
the PR Coverage log gives a tighter GitHub-runner exact count.
Driven so far on main: **1986 lines / 437 regions** out. Cluster 10 branch-local delta: **+77 lines /
+12 regions** beyond main's stable cap, or **+84 lines / +16 regions** versus the same-machine
origin/main baseline.

Test suites added (all in Tests/OuroWorkbenchAppViewsTests/):
WorkbenchViewModelBossActionTests, WorkbenchViewModelPerformCommandTests,
WorkbenchViewModelOnboardingFlowsTests, WorkbenchViewModelReleaseBugDiagTests,
WorkbenchViewModelStartupStateTests, WorkbenchViewModelOnboardingHandlersTests.

## Remaining drivable clusters (biggest-first, from vm-uncovered-lines.txt / vm-gate-scope.md)

- `markTerminated` (L9639, ~107) — exit/attention reconciliation logic (machinery-touching;
  the notification/attention LOGIC drives, the NSUserNotification/post is the boundary).
- `load` (L9864, ~89) — state load/migration (FileManager-backed; the migration LOGIC drives via
  the hermetic store, the literal file read is the seam).
- onboarding tail: `completeFirstRunBootstrap` (54), `runOnboardingProviderCheck` (57, process
  seam), `runOnboardingRepairStepNatively` (42), `makeFirstRunBootstrapEffects` (39),
  `scanForOnboardingSessions` (30), the start* handlers (startRepairAgent/startVerifyProvider/
  startSelectLane/startRegisterWorkbenchMCP/startRefreshProvider/startEnsureDaemon — each ~25-36).
- attention/notification: `applyAttentionSignal` (38), `reconcileStartupAttentionWithLiveSessions`
  (42), `postNeedsMeNotification` (37), `postUnexpectedExitNotification` (36), `applyAttentionSignal`.
- session lifecycle: `deleteCustomSession` (30), `launchAutoResumeSessionsOnStartup` (31),
  `backfillSessionIdsForFlushedRuns` (25), `revealLatestTranscript` (28).
- boss flows: `runBossCheckIn` (33), `runBossWatchTick` (37), `applyExternalActionRequests` (28),
  `runExternalActionPump` (28).
- the long tail of ~250 smaller logic decls (3-25 lines each).

## Genuine-carve floor (do NOT drive — ~107 syscall lines + async loops + llvm-synth)

live-PTY `TerminalSessionController.start()`/`TerminalPane`; literal subprocess
`Process()/run()/waitUntilExit()/Pipe()/FileHandle` lines (provider-check, login-shell-PATH,
screen-ls, support-diagnostics — driven UP TO the syscall via the closure seams);
`NSApp.terminate`/`NSWorkspace`/`NSPasteboard`; `submitBugReport`'s `captureKeyWindowPNG` →
`NSApp` IUO trap; `runBossWatchLoop` `while !Task.isCancelled` + `Task.sleep`; llvm-synth
autoclosure/resume-epilogue artifacts.

## Operating notes for a continuation
- Branch each cluster off the LATEST origin/main; VERSION = main's + 1 (others merge concurrently —
  expect drift, rebase + re-bump).
- Shell dep churns frequently; bump inline if the freshness gate would fail (verify HeaderView
  snapshots byte-identical at the new pin — no regen needed so far).
- `applyBossAction` was widened private→internal; its source-marker WiringTests
  (BossInjectionGate/ReplayDedup/StartSequenceAwait) were updated to the `func` marker — watch for
  similar source-introspection tests when widening other private funcs.
- DaemonLiveness allowlist is at 2/2 (the :159 + :171 synthesized epilogues).
- LESSON (#364): set each VM cluster's allowlist to the STABLE MAX, not the bare PR-time minimum —
  the VM's async/timing regions oscillate ±1 between runs, so the bare minimum reds main post-merge.
  Probe-then-set gives the PR-time floor; add a small buffer (or re-measure post-merge) for the
  oscillating regions, documented as class-(C) tolerance. Cover-first the identifiable timing-races.
