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
| 9 | #372 | 0.1.200 | reconcileStartupAttention + launchAutoResume + reapOrphanedScreen + applyExternalActionRequests + scan/startBossReconstruction/selectLane/registerMCP/repairAgent guards | **4288 / 1336** |

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
Cluster 9 result: CI residuals 4284/1334 and 4282/1332 across #372's final two Coverage jobs;
allowlist set to STABLE MAX 4288/1336 (higher observed residual +4/+2 class-C oscillation tolerance,
per the cluster-7 observed region oscillation). Drives the startup-reconcile + external-action-apply + onboarding-scan
logic + the start* handlers cluster 7 did NOT take (selectLane / registerWorkbenchMCP / repairAgent
skip guards). New seam: `spawnPersistentScreenQuit` (argv-based reaper quit; default = the shared
off-main+watchdog `spawnScreenQuit`; reaper wiring-pin updated + a seam-default-routing pin added —
NOTE: the per-entry `quitPersistentScreenIfNeeded` STAYS on `Self.spawnScreenQuit` so #370's
quitHelper pin is unaffected). `applyExternalActionRequests` + `backfillSessionIdsForFlushedRuns`
widened private→internal (ReplayDedup/SessionIdBackfill wiring markers → `func` form). MULTI-AGENT
NOTE: this PR was rebased onto main AFTER #368 (a concurrent cluster-7 PR) merged — its start*
verify/refresh tests were DROPPED as duplicates of #368, leaving the non-overlapping remainder.
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
Current (after #372): **4288 lines / 1336 regions** — the STABLE MAX (CI exact 4284/1334 plus the
documented +4/+2 class-(C) oscillation tolerance). 59.1% line / 52.0% region.
Driven so far: **1604 lines / 360 regions** out.

Test suites added (all in Tests/OuroWorkbenchAppViewsTests/):
WorkbenchViewModelBossActionTests, WorkbenchViewModelPerformCommandTests,
WorkbenchViewModelOnboardingFlowsTests, WorkbenchViewModelReleaseBugDiagTests,
WorkbenchViewModelStartupReconcileTests.

## Remaining drivable clusters (biggest-first, from vm-uncovered-lines.txt / vm-gate-scope.md)

- `load` (L9864, ~89) — state load/migration (FileManager-backed; the migration LOGIC drives via
  the hermetic store, the literal file read is the seam).
- onboarding tail: `runOnboardingProviderCheck` (57, process seam),
  `runOnboardingRepairStepNatively` (42), `makeFirstRunBootstrapEffects` (39).
- attention/notification: `postNeedsMeNotification` (37), `postUnexpectedExitNotification` (36).
- boss flows: `runBossCheckIn` (33), `runExternalActionPump` (28).
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
