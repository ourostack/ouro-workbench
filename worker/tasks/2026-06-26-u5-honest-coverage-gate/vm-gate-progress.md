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
| 9 | (open) | 0.1.200 | BIG BATCH: commandPaletteItems (all cmd arms) + load (normal/first-run/lossy-salvage/quarantine) + startup reconcile/recover/auto-resume + reapOrphanedScreen + reclassify/backfill folds + prepareForTermination + stopAll + drainExternalActionRequests | PROBE 3856/1252 |

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
Cluster 9 (BIG BATCH, startup / state-load / session lifecycle, v0.1.200, open PR): 39 tests drive
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
arm (store-internal, not seed-forceable). LOCAL (Swift 6.3.3) drove 4482/1371 → 3856/1252 (626 lines /
119 regions OUT). PROBE 3856/1252; CI Coverage prints the exact residual → set the stable max.

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
Current (main): **5102 lines / 1515 regions** — the STABLE MAX (the bare 5098/1514 minimum red-ed
main post-merge on an oscillating async region; set to the post-merge-observed stable count per the
class-(C) GATED-FILE OSCILLATION protocol). 51.4% line / 47.0% region.
Driven so far: **794 lines / 182 regions** out.

Test suites added (all in Tests/OuroWorkbenchAppViewsTests/):
WorkbenchViewModelBossActionTests, WorkbenchViewModelPerformCommandTests,
WorkbenchViewModelOnboardingFlowsTests, WorkbenchViewModelReleaseBugDiagTests.

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
