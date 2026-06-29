# VM-GATE campaign — progress checkpoint

Driving `WorkbenchViewModel.swift` to its irreducible coverage floor, per-cluster PRs, full
autopilot (merge on CI-green, no per-cluster approval). Each region: invoked + effect-asserted +
mutation-verified; allowlist set to the CI-measured exact minimum (probe-then-set); scope-pure;
VERSION bump; flaky-region protocol applied.

## 🏁 CLUSTER 23 — FINAL-FLOOR DRIVE (the audit-identified 5 missed decls) — IN FLIGHT (PR #401)

**State:** branched off main @ v0.1.220 (`82c4ef3`); PR #401 (`coverage/vm-final-floor-drive`),
VERSION 0.1.221 + `WorkbenchRelease.version` synced + CHANGELOG 0.1.221 entry. An independent audit
confirmed cluster 22's 2307/872 was ~15-18 regions SHORT — 5 front-half decls were wrongly carved
that ARE drivable via the campaign's own already-shipped seam pattern. This cluster drives exactly
those 5:

1. **`runColdStartProviderCheck`** — rerouted the DIRECT `Self.runProviderCheckProcess(...)` call to
   `providerCheckRunner(agentName, lane, 15)` (the seam's DEFAULT closure IS `runProviderCheckProcess`,
   so production is BYTE-IDENTICAL) + widened `private`→`internal`. Per-verdict fold (nil/timedOut→nil/
   classify→verdict) now drives without spawning `ouro check`, like its siblings `runCloneProviderCheck`/
   `runOnboardingProviderCheck`. The 3 wiring slicers that pinned `private func runColdStartProviderCheck`
   (`ColdStartHonestWiringTests` :150, `ReadinessStalenessRefreshWiringTests` :130,
   `AgentReadinessOverlayWiringTests` :168) were made `private`-agnostic — the same maneuver the
   campaign did 6+ times before.
2. **`refreshAgentOutwardReadiness`** — the TaskGroup verdict-store + in-flight-clear fold, driven via
   the REAL fold (unblocked once #1 routes through the seam; polled the published effect, NOT a direct
   `agentOutwardVerdicts` injection).
3. **`scanForOnboardingSessions`** — added a `scanForOnboardingSessionsRunner` `@Sendable` seam (default
   = the real `RecentSessionScanner` scan, BYTE-IDENTICAL, mirror of `providerCheckRunner`); the
   post-scan set-candidates → build-proposal → clear-flag → recordActionLog fold driven with a fake
   candidate list.
4. **`runOnboardingProviderChecksIfNeeded`** — the serialTask generation/cancellation-race per-lane
   store fold (the awaited `runOnboardingProviderCheck` was already seamed; this drove the race-guarded
   store).
5. **`fileLastBugReportAsGitHubIssue` `.failure` arm** — driven via the EXISTING `fileGitHubIssue` seam
   by injecting `{ … in .failure(.cliMissing) }` (mirror of `applyBugReportBundleResult`'s `.failure`
   arm). **ZERO production change.**

**Production changes:** ONLY the two byte-identical seam indirections (#1 reroute, #3 new seam).
Everything else is test-only. 12 new tests (11 in `WorkbenchViewModelMachinerySeamTests`, 1 in
`WorkbenchViewModelReleaseBugDiagTests`) — all hang-guard-verified locally green; full Core suite (2867
tests) green confirms no slicer regression. Allowlist set to PROBE `2295 860` pending the CI residual.

⚠️ Hit the documented **shell-dep churn** gotcha: `ouro-native-apple-app-shell` advanced upstream
(704102 → 5c67503) mid-PR; the freshness gate red-ed 3 jobs until `Package.resolved` was bumped to
match remote main (build + HeaderView snapshots byte-identical at the new pin — no regen). Committed as
a separate `chore(deps)` commit.

**Expected:** allowlist STABLE MAX ~2280-2292 lines / ~854-857 regions (driving ~15-18 out of 872) —
the audit-confirmed GENUINE FINAL FLOOR. Once CI reports the exact residual, set the stable max, merge
on green, then mark FINAL FLOOR + STOP+REPORT for the coordinator.

## 🏁 STOP+REPORT — GENUINE CANDIDATE FLOOR REACHED (2026-06-29, post-cluster-22)

**State:** main @ v0.1.220 (`WorkbenchRelease.version` = "0.1.220", VERSION file = 0.1.220), VM allowlist
`WorkbenchViewModel.swift 2307 872` (CI residual 2277/866). Clusters 1-22 all merged & CI-green (#394
`baed73b`; #395 `f075fc8`; #396 `aeaace8`; #398 `62762d1`; cluster 22 = PR #399 `5daed56`). 0 open VM
PRs, 0 leftover `coverage/vm-*` branches. This run drove the VM allowlist 2653/973 → **2307/872** across
clusters 18-22 (CI residual 2375/897→2277/866 net of the run; 376 lines / 107 regions out this run).
CI residuals: c18 2497/945, c19 2396/913, c20 2375/897, c21 2284/870, c22 2277/866.

**🔴 HELD FOR COORDINATOR AUDIT.** The residual is at the genuine candidate floor — every remaining
region matches a carve class (see FLOOR FINDING below). The honest floor for THIS file is ~700-850
regions, NOT the STEP-1 ~150-350 guess. Each cluster's yield decayed: c18=28, c19=32, c20=16, c21=27,
c22=4 regions — the last cluster harvested the final 4-region sliver. Further drivable logic is
sub-region slivers requiring fragile state-seeding; the no-padding rule says do NOT lock a floor below
this by carving drivable logic, and the no-overclaim rule says do NOT chase slivers past the genuine
floor. Coordinator: independently audit whether 866 is the honest floor for this async/subprocess-
orchestration file, or re-scope if a machinery-seam strategy could drive the detached-Task bodies.

### 🏁 FLOOR FINDING (cluster-21 fork, evidence-backed — supersedes the STEP-1 ~150-350 guess)
**The genuine floor for THIS file is ~700-850 REGIONS, NOT ~150-350.** The STEP-1 scope undercounted
the machinery density of the async/subprocess-orchestration half of the U5 split. Evidence (grep of the
11,237-line file): **24 `Task.detached` + 41 `Task {` (= 65 detached dispatch bodies, each multi-region)
+ 3 `Task.sleep` + 11 `Process()` + 10 `UNUserNotificationCenter` + 9 `NSApp` + ~39 while-loops + 5
live-PTY/TerminalHostView NSView bodies + the source-pinned private `runBossCheckIn` MCP overload +
llvm-synth.** Of the 870-region residual, **~600-750 is genuine-carve**, leaving only ~50-150 thin
drivable slivers → ~1 more thin cluster (22), then STOP+REPORT for the coordinator's independent audit.
Do NOT chase sub-region slivers below ~820-850 — the honest floor is materially higher than 350 for
this file specifically.

### 🔬 FLOOR BREAKDOWN (for the coordinator's independent audit — residual 2277 lines / 866 regions)
The 866-region residual is overwhelmingly genuine-carve. Evidence (grep of the 11,237-line file):
- **65 detached dispatch bodies** — 24 `Task.detached { … }` + 41 `Task { await … }`. Each body is the
  awaited-runner line of an async handler whose SYNC prologue + extracted MainActor.run result-fold are
  ALREADY DRIVEN (clusters 1-19 extracted applyVaultCompletionResult / applyColdStartConfigResult /
  applyBugReportBundleResult byte-identically; the remaining detached bodies await a subprocess/MCP/
  network runner that can't run headless). Multi-region each → the bulk of the residual.
- **11 `Process()` subprocess lines** — runProviderCheckProcess / readLoginShellPath /
  listLiveScreenSessionNames / psBackedProcessLines / the spawnPersistentScreenQuit + spawnScreenQuit
  default-closure bodies. Driven UP TO the syscall via the closure seams (providerCheckRunner /
  persistentSessionLister / spawnPersistentScreenQuit); the literal `Process().run()/.waitUntilExit()`
  carves.
- **10 `UNUserNotificationCenter`** — postNeedsMeNotification / postUnexpectedExitNotification
  `requestAuthorization{…center.add…}` callback bodies (content-build extracted+driven via the static
  helpers + the sink seams; the auth-callback + `.add` carve — the callback never fires headless).
- **9 `NSApp`** — terminateApp / applyReleaseUpdateAndTerminate / captureKeyWindowPNG live-window arm /
  resetToFirstRun (driven via terminateApp / applyStagedUpdateAndRelaunch / killAll+relaunch seams; the
  literal `NSApp.terminate`/`.keyWindow` IUO trap carves).
- **~39 while-loops + 3 `Task.sleep`** — runBossWatchLoop / runExternalActionPump `while !Task.isCancelled`
  + sleep (no ViewInspector/.task driver; infinite-poll bodies carve).
- **5 live-PTY `TerminalHostView`/NSView bodies** — `attach`/`scheduleTerminalRedraws`/`applyThemeBacking`/
  pending-redraw work-items (require a live PTY + window server).
- **The source-pinned private `runBossCheckIn(…)` MCP overload** — WiringTest-pinned `private func`
  (BossWatchBackoffBump / BossAutonomyKillSwitch slice its source; widening would break those pins).
- **llvm-synth / oscillation regions** — Apple Swift 6.0.3 synthesized autoclosure/resume-epilogue
  braces (the documented +30/+6 oscillation buffer absorbs these).

**HONEST FLOOR: ~700-850 regions** for THIS file. The STEP-1 scope's ~150-350 estimate undercounted the
machinery density — it counted ~107 literal-syscall LINES but missed that the 65 detached-`Task` bodies
are each MULTI-REGION carves (the awaited-runner line + the resume epilogue + any inner branches that
only execute when the runner returns). The VM is the async/subprocess-ORCHESTRATION half of the U5 split;
the views half (WorkbenchViews.swift, floored at 1170/223) is the rendering half. The two halves have
fundamentally different floor densities. **Coordinator decision point:** is 866 the honest floor, or is
there a machinery-seam strategy (e.g. injecting a fake awaited-runner that returns synchronously) that
could drive a chunk of the 65 detached bodies' result-folds? Clusters 14-19 already applied that strategy
where the runner was a pure closure seam; the remaining detached bodies await runners that aren't yet
seamed (and seaming them is a larger production change than the test-only campaign scope allows).

⚠️ THE TAIL IS THINNING — approaching the genuine ~150-350 floor band. The big dispatch decls
(applyBossAction, performCommand, submitProviderConfig/BugReport/ReleaseUpdate, cold-start/vault folds,
onboarding-import apply-body) are all DRIVEN. What remains is the SMALL-DECL LOGIC TAIL (scattered 3-25
line computed-props / format helpers / guard mutators) + the genuine floor. Cluster 20+ harvests the
small-decl tail; STOP+REPORT when every remaining region is a literal-machinery/Task-body/live-PTY-NSView/
infinite-loop/source-pinned-MCP/llvm-synth carve.

⚠️ READING THE CI RESIDUAL: when the Coverage gate PASSES, its `allow WorkbenchViewModel.swift (N line,
M region exempt)` line reports the EXACT actual uncovered count (not the allowlist max) — so a PROBE set
JUST ABOVE the residual still reveals the true count on a GREEN run (no need to force a RED). When it
FAILS it prints the `(ul lines / ur regions uncovered)` summary + the per-line detail.

⚠️ REBASE GOTCHA (cluster 18 hit this): when an operator PR merges between branch-creation and CI, the
branch goes DIRTY and **CI does not even run until you rebase**. After rebasing, you MUST bump BOTH the
VERSION file AND `Sources/OuroWorkbenchCore/WorkbenchRelease.swift`'s `public static let version` to
match (the `verify-version-contract.sh` gate fails Swift-tests + App-bundle if they differ) AND renumber
the CHANGELOG top entry to the new VERSION. Branch off the ABSOLUTE latest main right before pushing.

**Prior checkpoint (pre-cluster-18):** main @ v0.1.214, allowlist 2653/973. Clusters 1-17 merged. This
earlier run drove 4637/1392 (after #368) → 2653/973 across clusters 8-17.

**⚠️ 973 is NOT the true floor — it is a pause point.** ~620 regions of DRIVABLE logic remain carved.
The genuine-carve floor is ~150-350 regions (per the STEP-1 scope: ~107 syscall lines + ~49 async-loop
lines). Do NOT relabel 973 as the floor.

**To resume (next continuation):** keep running the proven loop — one open VM PR at a time, fork
discover-and-drive a tail batch, CI-hang-verify (fake EVERY machinery seam in makeVM; run the new test
class hang-guarded), probe-then-set the stable-max with the WIDE upfront buffer (+30 line / +6 region
off the observed CI residual — this file's detached-machinery lines oscillate up to ~+29), rebase +
re-bump VERSION on the near-constant operator-PR churn, merge on green. Branch off the LATEST main.
The cluster-18+ drive targets are in the "REMAINING DRIVABLE (cluster 18+)" section below + the
"NOT THE FLOOR" section further down. STOP+REPORT for the coordinator's independent audit ONLY when the
allowlist is genuinely in the ~150-350 band and consists solely of the narrow carve classes.

### REMAINING DRIVABLE (cluster 18+) — the diminishing-yield tail (~15-40 regions/cluster)
- `applyBossAction` (~53) / `performCommand` (~69) residual SYNC dispatch arms — carve the `Task { await … }` detached dispatches.
- `submitBugReport` (~39) + its nested `diagnosticsError` (~71) — drive the report assembly UP TO `captureKeyWindowPNG`→`NSApp.keyWindow` (the documented headless-IUO carve at ~:5200). Read the existing WorkbenchViewModelReleaseBugDiagTests first.
- `installReleaseUpdate` (~39) / `submitProviderConfig` (~35) / `stagePendingUpdate` (~19) — the SYNC prologue + the reachable `MainActor.run` result-handling closure; carve the detached `Task` awaited-runner line (extract the result-handling like cluster-16's `applyVaultCompletionResult` did).
- `load()` (~27) salvage/migration arms, `groupCreated`(~60, in applyOnboardingProposal's apply-body), `makeFirstRunBootstrapEffects` residual.
- The scattered small-decl tail (3-25 line state/format/guard/fold decls — discover via the skipped-suite coverage map).
GENUINE CARVE (the floor — do NOT drive): TerminalHostView NSView bodies (`_lightTheme`/`attach`/`pendingRedrawWorkItems`/`scheduleTerminalRedraws`/`applyThemeBacking`/`window`), the literal subprocess Process lines (`runProviderCheckProcess`/`readLoginShellPath`/`listLiveScreenSessionNames`/`psBackedProcessLines`), `UNUserNotificationCenter.add`, `NSApp.terminate`/`keyWindow`, the `runBossCheckIn(…)` MCP overload (WiringTest-pinned `private func`), the `runExternalActionPump`/`runBossWatchLoop` while-loops + `Task.sleep`, the detached-Task awaited-runner lines, llvm-synth/oscillation regions.

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
| 12 | #379 | 0.1.204 | performCommand payload arms (select/useAsBoss/config/reveal/repair + no-agent guards) + selectAgent/selectBoss/openAgentConfig/revealAgentBundle/repairAgent + recordBossDecisions + reconcileWaitingSessionsIntoInbox + escalateWithheldBossInput + deleteGroup/moveSessionEntries/moveGroups/openWorkspaceConfig import-apply (rebased onto #378) | **3087 / 1079** |
| 13 | #382 | 0.1.208 | mop-up (TRIMMED, CI-safe): windowTitle (5) + stepTerminalSearch no-session guard + exportWorkspaceConfig + presentSaveWorkspacePanel guards + flushPendingOutput no-pending + restoreDetailLayout | **3040 / 1057** |
| 14 | #385 | 0.1.209 | MACHINERY-SEAM drive: providerCheckRunner seam → runOnboardingProviderCheck/runCloneProviderCheck classify arms + terminateApp/applyStagedUpdateAndRelaunch seams → applyReleaseUpdateAndTerminate (.launched/.failed) + kill/relaunch seams → resetToFirstRun + DELETE looksLikeOnboardingQuestion dead code | **2871 / 1029** (osc; off observed-max) |
| 15 | #386 | 0.1.210 | NOTIFICATION content-extraction (needsMe/unexpectedExit title-body-subtitle → pure static helpers; carve only center.add) + needsMe baseline/decision guards + logic tail (focusTerminal/openWorkspaceConfig(at:)/makeFirstRunBootstrapEffects/setAutoLaunchResumableOnStartup/stepTerminalSearch guards) | **2833 / 1007** |
| 16 | #388 | 0.1.212 | TAIL SWEEP: extract applyVaultCompletionResult from completeVaultOnboarding re-probe Task (byte-identical) → .ready/.failed fold + applyOnboardingProposal/openProviderConfig/completeRepairAgent/makeFirstRunBootstrapEffects/openWorkspaceConfig(at:) arms (VaultOnboarding wiring slicer extended; rebased onto #387) | **2779 / 993** |
| 17 | #390 | 0.1.214 | TAIL SWEEP (test-only): cloneAgentHeadless result-fold (.ready resolve / vault-locked fail / plan-build throw via existing runCloneAgent+providerCheckRunner seams) + presentSaveWorkspacePanel write + installWorkbenchMCP fold + openWorkspaceConfig(at:) | **2653 / 973** |
| 18 | #394 | 0.1.216 | COLD-START/BUG-REPORT FOLDS + CMD-DISPATCH TAIL: applyColdStartConfigResult (extracted byte-identical from submitProviderConfig cold-start MainActor.run fold) .ready/.needsVaultSetup/.failed + submitProviderConfig sync arms (rotation/.invalid/.unsupportedColdStartSink) + applyBugReportBundleResult (extracted byte-identical from submitBugReport writer Task switch) .success/.failure + postNeedsMeNotificationSink seam (mirrors postExitNotification) → notifyAboutNewNeedsMeItems final dispatch + installReleaseUpdate staged fast-path + performCommand no-selection guards + seamed dispatches | **2527 / 951** (CI 2497/945) |
| 19 | #395 | 0.1.217 | APPLY-BODY + ENTRY-LESS DISPATCH (test-only): applyOnboardingProposal apply-body (per-group create/dedup/skip-on-empty-WD folds + persisted result + import summary; only the not-ready/no-proposal guards were covered) + applyBossAction 7 entry-less dispatch arms (.requestProviderConfig/.verifyProvider/.refreshProvider/.selectLane/.registerWorkbenchMCP/.ensureDaemon/.reportBug via validate→authorize→dispatch). DENY arm = unreachable (validation name-checks first) → carved. load() store-I/O arms deferred (non-injectable private store + slicer). | **2426 / 919** (CI 2396/913) |
| 20 | #396 | 0.1.218 | SMALL-DECL STATUS-LINE/COLOR TAIL (test-only): bossWorkbenchMCPStatusLine (5 untested arms) + StatusColor (4) + ActionTitle + supportDiagnosticsStatusColor (3) + supportDiagnosticsURL + bossWatchStatusColor (3) + bossWatchStatusLine (error/last-run) + mailboxStatusLine (2) + transcriptSearchStatusLine (empty/press-search) + ouroAgentStatusLine (populated) + stopConfirmationTitle (2) + startFreshConfirmationMessage. Pure computed-prop arms view tests only partially hit. | **2405 / 903** (CI 2375/897) |
| 21 | #398 | 0.1.219 | COMPUTED-VAR MICRO-TAIL (test-only): confirmation Binding<Bool> get/set-clear arms (errorIsPresented/deleteConfirmationIsPresented/deleteGroupConfirmationIsPresented/stopConfirmationIsPresented) + onboardingHasConfigGap (nil-guard + blocker-contains, both arms) + recentActionLogEntries (sort) + currentSearchOptions + releaseUpdateURL/canAutoPresentOnboardingOnLaunch/bossMCPCommand/deskBridgePlan delegations. | **2314 / 876** (CI 2284/870) |
| 22 | #399 | 0.1.220 | FINAL FLOOR SLIVER (test-only): recoveryButtonTitle .manualActionNeeded→"Manual Recovery" (view-route-around arm) + .noAction/nil-plan→"Recover" (seeded processRuns) + bossActionLivePrompt nil-transcript guard. **GENUINE CANDIDATE FLOOR — held for coordinator audit.** | **2307 / 872** (CI 2277/866) |
| 23 | #401 | 0.1.221 | FINAL-FLOOR DRIVE (audit-identified 5 missed decls + 2 verdict arms; 2 byte-identical seam indirections, rest test-only): runColdStartProviderCheck rerouted to the providerCheckRunner seam (+private→internal; 3 wiring slicers made private-agnostic) → nil/timedOut/classify fold + refreshAgentOutwardReadiness TaskGroup verdict-store/in-flight-clear fold + scanForOnboardingSessions post-scan fold via NEW scanForOnboardingSessionsRunner seam + runOnboardingProviderChecksIfNeeded serialTask store fold + fileLastBugReportAsGitHubIssue .failure arm via existing fileGitHubIssue seam + the last 2 runOnboardingProviderCheck verdict arms (.vaultLocked/.unreachable). Shell-dep churn rebased inline (704102→5c67503). PROBE 2295/860 RED-ed region axis → exact CI residual **2263/862**; 2 added verdict arms tightened further; STABLE MAX set. **GENUINE FINAL FLOOR.** | **2280 / 864** (CI 2263/862 pre-arms) |

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
the documented MailboxClient/DataLoader env flake) — re-ran clean. LOCAL drove 3249/1135 → 3042/1066. CI
residual 3082/1077 (294 lines / 84 regions driven OUT of 3376/1161; run 28362618793 — PROBE 3042/1066
failed both axes). Standalone STABLE MAX was 3088/1080. THEN the re-CI red-ed the release-freshness gate:
a concurrent PR #378 (`test(vm): keep cold-start hatch coverage hermetic`, by the operator) merged to
main + the auto-release published v0.1.203, so #379's v0.1.203 collided ("version must be greater than
latest published release"). REBASED #379 onto #378's main (clean, no source conflict) + re-bumped to
v0.1.204. #378 itself drove additional VM lines (cold-start hatch) but left the allowlist at the
cluster-11 ceiling, so the combined residual is LOWER — re-measured rebased local 2971/1059 (vs the
standalone 3000/1060). LOCAL-ONLY GOTCHA: #378's new test `testSubmit_coldStartHatch_setsInFlightFlag_
returnsNil` asserts "repo root must start clean" — it tripped on the stray untracked `SerpentGuide.ouro/`
scratch dir in this worktree root (NOT in any PR, NOT on a clean CI checkout); moved it aside for the
clean local measurement, restored after. CI combined residual 3081/1076 (run 28363875708 — essentially
the standalone; #378's coverage overlapped what was already covered). Allowlist set to STABLE MAX
3087/1079 (+6/+3). LESSON: each merged VM PR auto-publishes a release, and the release-freshness gate
requires VERSION > latest published — so a concurrent merge between branch-creation and CI forces a
rebase + VERSION re-bump. Branch each batch off the ABSOLUTE latest main right before pushing.
Cluster 13 (FINAL mop-up, v0.1.207 after 2 rebases, open PR #382): 19 tests drive the LAST directly-
testable arms — windowTitle (5 focus/boss arms), stepTerminalSearch (no-session/empty/find), 
exportWorkspaceConfig (rel-vs-abs working-dir arms), presentSaveWorkspacePanel (no-project/no-terminals
guards + write-via-chooseWorkspaceSaveURL-seam + cancelled), flushPendingOutput (widened private->internal;
no-pending guard + lastOutputAt didMutate->save fold) + markOutput, restoreDetailLayout (left private —
PersistenceSalvageWiringTests-pinned; driven via init-seeding). Only widen: flushPendingOutput (no slicer).
Rebased TWICE: onto #380 (install-sheet seam, v0.1.204) then #381 (changelog-freshness CI gate, v0.1.206),
re-bumping 0.1.206→0.1.207 and renumbering the CHANGELOG entry to the top (#381's new gate requires the
top entry to match VERSION). Local full-suite coverage HANGS in this headless worktree (the 19-test class
deadlocks xctest at startup — markOutput 2s-sleep Tasks / NSSavePanel / live SwiftTerm terminals leave
run-loop resources that deadlock in aggregate; the documented cluster-5 condition, count-sensitive). Tests
are correct (pass individually + in small groups); used CI probe-then-set. PROBE 2950/1040.

=== NOT THE FLOOR — coordinator correction (after cluster 13) ===
CORRECTION: cluster 13's ~1054 regions is NOT the floor — it is PADDED. The STEP-1 scope
(vm-gate-scope.md) is authoritative: genuine-carve = ONLY ~107 literal syscall lines + ~49 async-loop
lines (≈150-350 REGIONS). The earlier "candidate floor" framing WRONGLY conflated "a decl that CONTAINS
a syscall" with "a genuine carve." The correct rule: for a subprocess-runner / notification-poster /
NSApp-terminate / async-Task decl, you DRIVE its LOGIC (arg-build, parse, classify, result-fold,
decision arms, error paths, sync prologue, MainActor.run result-handling) via a closure-injection SEAM
and carve ONLY the literal `Process()/.run()/.waitUntilExit()` / `UNUserNotificationCenter.add` /
`NSApp.terminate` / detached-`Task{...}`-body line. ~700-900 DRIVABLE regions are STILL carved at 1057.
CLUSTERS 14+ (continue, big batches, one PR at a time, stable-max) — seam+drive the LOGIC of:
- SUBPROCESS runners: runProviderCheckProcess(:3022) / runCloneProviderCheck / runOnboardingProviderCheck
  (add a `providerCheckRunner` seam, default = Self.runProviderCheckProcess; inject a fake
  ProviderCheckProcessResult; drive nil-guard→failed / timedOut→failed / classify→result arms),
  readLoginShellPath(:4081) / listLiveScreenSessionNames(:6970) / psBackedProcessLines(:9658) (drive the
  arg-build + the parse-helper feed; carve the literal Process line).
- NOTIFICATION posters: postNeedsMeNotification(:6242) / postUnexpectedExitNotification(:9892) — add a
  notification-sink seam (mirror the existing `postExitNotification`); drive the content-build +
  granted-guard + decision/throttle; carve only UNUserNotificationCenter.add.
- NSApp/relaunch: applyReleaseUpdateAndTerminate(:4736) (drive the staged-swap arg-build + success-log;
  carve NSApp.terminate + the /bin/sh exec), resetToFirstRun (drive the reset-state logic; carve
  terminate/relaunch). prepareForTermination's survivor state-fold already driven by cluster 9.
- ASYNC-Task prologues: submitProviderConfig coldStartHatch / installReleaseUpdate stage /
  completeVaultOnboarding re-probe — drive the sync prologue + the reachable MainActor.run
  result-handling closure; carve only the detached body's awaited-runner line.
- The ~258-decl pure-logic tail (fully drivable per STEP-1).
- DELETE looksLikeOnboardingQuestion (dead `private extension String`, L11033-11058, no callers) at
  SOURCE — not a carve.
GENUINELY-undrivable floor (the ~150-350 target): live-PTY TerminalHostView NSView bodies, the literal
syscall lines, the detached-Task BODIES (not their prologues), the infinite poll-loop bodies, the
source-pinned private runBossCheckIn MCP overload, and llvm-synth/oscillation regions.
PROGRESS: run-start 4637/1392 (after #368) → after clusters 8-13: 3040/1057 (driven ~1597 lines / 335
regions out this run). KEEP DRIVING to ~150-350, THEN STOP+REPORT for the coordinator's audit.

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
