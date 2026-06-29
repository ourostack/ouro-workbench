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
| 10 | #375 | 0.1.201 | BIG BATCH: start*SelectLane/RegisterMCP/RepairAgent (skip+ack; the 3 carried from #369/#372/#374) + scan/startBossReconstruction guards + beginVault/credentialRotation/completeVault + runOnboardingRepairStepNatively + surfaceNativeRepairLine + makeFirstRunBootstrapEffects + openDeskBridgeSetup + installWorkbenchMCP | **3523 / 1209** |
| 11 | #377 | 0.1.202 | checkForReleaseUpdate + installReleaseUpdate/runAutoUpdateCheckIfDue/stagePendingUpdate guards + releaseUpdateStatusLine/Color + bugReportSessions/AgentNames/ExtraSections + reveal/openSupportDiagnostics + ensureDaemonRunningOnLaunch | **3376 / 1161** |
| 12 | (open) | 0.1.203 | performCommand payload arms (select/useAsBoss/config/reveal/repair + no-agent guards) + selectAgent/selectBoss/openAgentConfig/revealAgentBundle/repairAgent + recordBossDecisions + reconcileWaitingSessionsIntoInbox + escalateWithheldBossInput + deleteGroup/moveSessionEntries/moveGroups/openWorkspaceConfig import-apply | PROBE 3042/1066 |

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
arm (store-internal, not seed-forceable). CI residual 3902/1257 (650 lines / 121 regions driven OUT
of 4552/1378; run 28356481057 — the PROBE 3856/1252 FAILED on both axes, so the gate printed the
exact count). Allowlist set to STABLE MAX 3906/1259 (+4 line / +2 region class-(C) buffer). The
#369→#372 startup-reconcile path (resurrected by a leftover prior-doer process as a 2nd concurrent
PR) was CLOSED by the coordinator as superseded — #373 drove its substantive scope + much more. The 5
onboarding skip-guards unique to #372 (scanForOnboardingSessions / startBossReconstruction /
startSelectLane / startRegisterWorkbenchMCP / startRepairAgent) are carried forward into Batch 2.
The leftover process re-pushed the SAME superseded work a THIRD time as #374
(`vm-cluster9-startup-reconcile`, stale df59ac1 base, allowlist 4288/1336 which would REGRESS main) —
also CLOSED + branch deleted on the same supersession basis.
Cluster 10 (BIG BATCH, onboarding / provider / vault, v0.1.201, open PR): 32 tests drive the boss-
issued onboarding dispatchers startSelectLane / startRegisterWorkbenchMCP / startRepairAgent (skip-
guard + in-flight-ack arms — the 3 carried-forward guards), scanForOnboardingSessions +
startBossReconstruction guards, beginVaultOnboarding / beginCredentialRotation / completeVaultOnboarding
(sync prologue; the detached re-probe Task is the boundary), runOnboardingRepairStepNatively (all 5
arms) + surfaceNativeRepairLine, makeFirstRunBootstrapEffects, openDeskBridgeSetup, installWorkbenchMCP.
Widened private→internal (6 funcs + 4 vault vars; NO WiringTest slicer referenced any). Carved: every
start* runner Task body, submitProviderConfig's coldStartHatch Task, completeVaultOnboarding re-probe
Task, runCloneProviderCheck (live `ouro check`), the begin* createCustomSession-nil launch-fail guards.
DEAD-CODE FLAG (for coordinator): `looksLikeOnboardingQuestion` is a `private extension String` var
with NO callers in the VM — not drivable, not machinery; a deletion candidate (NOT touched here).
CI residual 3508/1205 (398 lines / 54 regions driven OUT of 3906/1259; run 28358230024). NOTE: this
batch hit a WIDE class-(C) oscillation — two CI runs measured 3508/1205 then 3519/1207 (+11 LINES),
the toggling lines being detached-machinery call sites (readLoginShellPath() inside a Task.detached :4055,
spawnScreenQuit( default-closure body :10818) whose region counter flakes on whether the detached Task
ran before the profdata snapshot. The first stable-max 3512/1207 (+4/+2 off the lower run) RED-ed the
re-run on line 3519>3512. Re-set to STABLE MAX 3523/1209 = observed-max 3519/1207 + (+4 line / +2 region)
margin. LESSON: when a batch touches detached-Task/subprocess boundary lines, the line-axis oscillation
can exceed the usual +4 — measure TWO runs (or set off the observed max) before trusting the buffer.
The leftover process re-pushed a 4th time as #376 (`vm-cluster10-onboarding-guards`, +104, pre-#375
base) — a strict SUBSET of #375 (same 6 guards, fewer tests) that would revert #375's test file and
regress the allowlist; CLOSED + branch deleted.
Cluster 11 (release-update / bug-report / diagnostics / daemon tail, v0.1.202, open PR): 28 tests drive
checkForReleaseUpdate (success via injected dataLoader / loader-throw .unavailable), installReleaseUpdate
(re-entrancy / snapshot-nil / planner-failure guards), runAutoUpdateCheckIfDue (once-guard / policy-gate /
enabled-due), stagePendingUpdate + applyStagedUpdateOnQuitIfNeeded (skip guards; widened), the
releaseUpdateStatusLine/Color computed props (every arm), bugReportSessions (widened) + bugReportAgentNames
+ bugReportExtraSections, reveal/openSupportDiagnostics, ensureDaemonRunningOnLaunch (empty-name guard +
injected DaemonManager(probe:.up) resumed arm). This batch is SMALLER (64 lines local) because the
release/bug/diag area is machinery-dense — carved: applyReleaseUpdateAndTerminate (NSApp.terminate +
applyAndRelaunch /bin/sh bundle-swap, DESTRUCTIVE in-test), installer.stage network download,
submitBugReport captureKeyWindowPNG->NSApp.keyWindow (documented floor), readLoginShellPath subprocess.
4 widens, no slicer touched. LOCAL drove 3418/1185 → 3354/1157. CI residual 3370/1158 (153 lines / 51
regions driven OUT of 3523/1209; run 28360595827 — PROBE 3354/1157 failed on both axes). Allowlist set
to STABLE MAX 3376/1161 with a WIDER +6 line / +3 region buffer (vs the usual +4/+2) to pre-absorb this
file's known ~11-line detached-machinery oscillation off the observed residual in ONE shot (no second-
run round-trip needed). Green on the first re-CI (after one re-run of a class-(A) DaemonLiveness
URLSession-timeout flake, unrelated to the VM).
Cluster 12 (boss / command-dispatch / workspace, v0.1.203, open PR): 30 tests drive performCommand's
payload dispatch arms (.selectAgent / .useSelectedAgentAsBoss / .openSelectedAgentConfig /
.revealSelectedAgentBundle / .repairSelectedAgent / .manageAgents, each + the focusedAgentForCommand
resolve + "No agent is selected" else-arm), the dispatch targets selectAgent (all 4 arms) / selectBoss /
openAgentConfig / revealAgentBundle (revealFileViewerSelectingURLs seam) / repairAgent (launchTerminalSession
seam), recordBossDecisions (empty-parse + recorded-decision), reconcileWaitingSessionsIntoInbox,
escalateWithheldBossInput (widened private->internal; record-once + dedupe), deleteGroup (last-ws / non-empty
/ empty arms), moveSessionEntries / moveGroups reorder, openWorkspaceConfig import-apply (created +
alreadyPresent). PROACTIVELY caught a CI-break: two WiringTests (BossWatchBackoffBump / BossAutonomyKillSwitch)
pin `private func runBossCheckIn(` — so the fork LEFT that private overload alone and drove via the public
entry (the only widen is escalateWithheldBossInput, no slicer). Carved: the `Task { runBossQuickQuestion/
refreshWorkspace }` detached dispatches, runExternalActionPump while-loop+Task.sleep, the private runBossCheckIn
daemon/MCP overload, openAgentConfig's NSWorkspace.open, the recoverUnconfirmed/sweepOrphaned prologue
(ReplayDedup-pinned). LOCAL crashed once on a headless `.shared`-URLSession network test (SIGTRAP signal-5,
the documented MailboxClient/DataLoader env flake) — re-ran clean. LOCAL drove 3249/1135 → 3042/1066. PROBE
3042/1066; CI prints exact → stable max (+6/+3 off observed, per this file's oscillation).

SOURCE-INTROSPECTION CAVEAT (reconfirmed, clusters 6+7+8+9+12): BEFORE widening a `private func` for a
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
