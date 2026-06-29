#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 14 — the machinery-SEAM drive.
///
/// Per the coordinator's correction: a decl that merely CONTAINS a syscall is NOT a genuine carve.
/// For each subprocess-runner / NSApp-terminate decl we DRIVE its LOGIC (arg-build, parse, classify,
/// result-fold, decision arms, error paths) via a closure-injection SEAM and carve ONLY the literal
/// `Process()/.run()` / `NSApp.terminate` / installer-bundle-swap line. New seams added (each default
/// byte-identical to the prior behavior — pure access/indirection, no behavior change):
///   • `providerCheckRunner` — the `ouro check` probe boundary. Drives `runOnboardingProviderCheck`
///     (nil-guard → "still setting up"; timedOut → "taking longer"; the classifier verdict switch →
///     .working/.passed + every non-working → .failed copy) and `runCloneProviderCheck` (nil-guard,
///     timedOut → nil, classify → verdict). Both widened private→internal.
///   • `terminateApp` + `applyStagedUpdateAndRelaunch` — drive `applyReleaseUpdateAndTerminate`'s
///     BOTH outcome arms (.launched success-log + isApplyingManualUpdate; .failedToLaunch error/
///     status restore + log). Widened private→internal.
///   • `killAllPersistentScreensOnReset` + `relaunchAfterExitOnReset` + `terminateApp` — drive
///     `resetToFirstRun`'s state-fold (the isResettingToFirstRun flag, the live-terminal terminate
///     loop, the factory data wipe) without spawning `screen`/`open` or killing the test process.
///
/// CARVED (still genuine machinery): the literal `runProviderCheckProcess` Process body, the real
/// `WorkbenchUpdateInstaller.applyAndRelaunch` bundle-swap, the real `NSApp.terminate`,
/// `killAllPersistentScreens`/`relaunchAfterExit` subprocesses — all behind the seam defaults.
@MainActor
final class WorkbenchViewModelMachinerySeamTests: XCTestCase {

    private static let projectId = UUID(uuidString: "C14F1A00-0000-0000-0000-0000000000A1")!
    private static let wsId = UUID(uuidString: "C14F1A00-0000-0000-0000-0000000000B1")!

    /// Build a hermetic VM with every machinery seam neutralized so no test reaches live machinery
    /// (subprocess / NSApp.terminate / NSSavePanel). Each test overrides the seam it drives.
    private func makeVM(boss: String = "boss") throws -> WorkbenchViewModel {
        try makeVMWithPaths(boss: boss).0
    }

    private func makeVMWithPaths(boss: String = "boss") throws -> (WorkbenchViewModel, WorkbenchPaths) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmseam-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: boss),
            bossWatchEnabled: false,
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp/vmseam")],
            processEntries: [],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: [])],
            processRuns: [])
        try WorkbenchStore(paths: paths).save(state)
        let m = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        m.launchTerminalSession = { _ in }
        m.chooseWorkspaceSaveURL = { _ in nil }
        m.chooseWorkspaceOpenURL = { _ in nil }
        // Machinery neutralized by default — no live subprocess / quit / relaunch / filesystem scan.
        m.providerCheckRunner = { _, _, _ in nil }
        m.terminateApp = {}
        m.killAllPersistentScreensOnReset = {}
        m.relaunchAfterExitOnReset = {}
        m.scanForOnboardingSessionsRunner = { _ in [] }
        return (m, paths)
    }

    // MARK: - runOnboardingProviderCheck (via providerCheckRunner seam)

    func testOnboardingProviderCheck_launchFailure_isFailedSettingUp() async throws {
        let m = try makeVM()
        m.providerCheckRunner = { _, _, _ in nil }  // launch failed → nil
        let result = await m.runOnboardingProviderCheck(agentName: "scout", lane: "main")
        XCTAssertEqual(result.state, .failed, "a nil runner result → .failed")
        XCTAssertTrue(result.detail.contains("still setting this up"), "the nil-guard copy")
        XCTAssertEqual(result.lane, "main")
    }

    func testOnboardingProviderCheck_timedOut_isFailedTakingLonger() async throws {
        let m = try makeVM()
        m.providerCheckRunner = { _, _, _ in
            ProviderCheckProcessResult(timedOut: true, terminationStatus: 0, output: "")
        }
        let result = await m.runOnboardingProviderCheck(agentName: "scout", lane: "main")
        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(result.detail.contains("taking longer than usual"), "the timedOut-guard copy")
    }

    func testOnboardingProviderCheck_working_isPassed() async throws {
        let m = try makeVM()
        let captured = OuroBox<(String, String, TimeInterval)?>(nil)
        m.providerCheckRunner = { agent, lane, budget in
            captured.value = (agent, lane, budget)
            return ProviderCheckProcessResult(timedOut: false, terminationStatus: 0, output: readyVerdictOutput)
        }
        let result = await m.runOnboardingProviderCheck(agentName: "scout", lane: "main")
        XCTAssertEqual(result.state, .passed, "a .working verdict → .passed")
        XCTAssertTrue(result.detail.contains("working"))
        // mutation-verified: the seam received the agent/lane/90s onboarding budget.
        XCTAssertEqual(captured.value?.0, "scout")
        XCTAssertEqual(captured.value?.1, "main")
        XCTAssertEqual(captured.value?.2, 90)
    }

    func testOnboardingProviderCheck_unauthorized_isFailedReconnectCopy() async throws {
        let m = try makeVM()
        m.providerCheckRunner = { _, _, _ in
            ProviderCheckProcessResult(timedOut: false, terminationStatus: 0, output: unauthorizedVerdictOutput)
        }
        let result = await m.runOnboardingProviderCheck(agentName: "scout", lane: "main")
        XCTAssertEqual(result.state, .failed, "a non-working verdict → .failed")
        XCTAssertTrue(result.detail.contains("credentials were rejected"), "the .unauthorized copy")
    }

    func testOnboardingProviderCheck_indeterminate_isFailedCouldntConfirm() async throws {
        let m = try makeVM()
        m.providerCheckRunner = { _, _, _ in
            // No verdict line → .indeterminate.
            ProviderCheckProcessResult(timedOut: false, terminationStatus: 0, output: "garbage with no verdict")
        }
        let result = await m.runOnboardingProviderCheck(agentName: "scout", lane: "main")
        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(result.detail.contains("couldn't confirm"), "the .indeterminate copy")
    }

    // VM-GATE FINAL FLOOR: the two remaining non-working verdict arms of runOnboardingProviderCheck
    // (.vaultLocked + .unreachable) — the sibling tests above only drove .working/.unauthorized/
    // .indeterminate. Each is drivable via the same providerCheckRunner seam with a verdict-line that
    // the F2 classifier maps to that verdict; no production change.

    func testOnboardingProviderCheck_vaultLocked_isFailedReconnectCredentialsCopy() async throws {
        let m = try makeVM()
        m.providerCheckRunner = { _, _, _ in
            ProviderCheckProcessResult(timedOut: false, terminationStatus: 0, output: vaultLockedVerdictOutput)
        }
        let result = await m.runOnboardingProviderCheck(agentName: "scout", lane: "main")
        XCTAssertEqual(result.state, .failed, "a .vaultLocked verdict → .failed")
        XCTAssertTrue(result.detail.contains("couldn't unlock your saved credentials"), "the .vaultLocked copy")
    }

    func testOnboardingProviderCheck_unreachable_isFailedCheckNetworkCopy() async throws {
        let m = try makeVM()
        m.providerCheckRunner = { _, _, _ in
            ProviderCheckProcessResult(timedOut: false, terminationStatus: 0, output: unreachableVerdictOutput)
        }
        let result = await m.runOnboardingProviderCheck(agentName: "scout", lane: "main")
        XCTAssertEqual(result.state, .failed, "an .unreachable verdict → .failed")
        XCTAssertTrue(result.detail.contains("couldn't reach this connection's provider"), "the .unreachable copy")
    }

    // MARK: - runCloneProviderCheck (via providerCheckRunner seam)

    func testCloneProviderCheck_launchFailure_isNil() async throws {
        let m = try makeVM()
        m.providerCheckRunner = { _, _, _ in nil }
        let verdict = await m.runCloneProviderCheck(agentName: "scout", lane: "outward")
        XCTAssertNil(verdict, "a nil runner result → nil (couldn't confirm, not a false-green)")
    }

    func testCloneProviderCheck_timedOut_isNil() async throws {
        let m = try makeVM()
        m.providerCheckRunner = { _, _, _ in
            ProviderCheckProcessResult(timedOut: true, terminationStatus: 0, output: readyVerdictOutput)
        }
        let verdict = await m.runCloneProviderCheck(agentName: "scout", lane: "outward")
        XCTAssertNil(verdict, "a timeout → nil even if truncated output looked ready")
    }

    func testCloneProviderCheck_working_classifiesWorking() async throws {
        let m = try makeVM()
        let captured = OuroBox<TimeInterval?>(nil)
        m.providerCheckRunner = { _, _, budget in
            captured.value = budget
            return ProviderCheckProcessResult(timedOut: false, terminationStatus: 0, output: readyVerdictOutput)
        }
        let verdict = await m.runCloneProviderCheck(agentName: "scout", lane: "outward")
        XCTAssertEqual(verdict, .working, "a ready verdict line classifies .working")
        XCTAssertEqual(captured.value, 15, "the clone probe uses the SHORT 15s budget")
    }

    func testCloneProviderCheck_unauthorized_classifiesUnauthorized() async throws {
        let m = try makeVM()
        m.providerCheckRunner = { _, _, _ in
            ProviderCheckProcessResult(timedOut: false, terminationStatus: 0, output: unauthorizedVerdictOutput)
        }
        let verdict = await m.runCloneProviderCheck(agentName: "scout", lane: "outward")
        XCTAssertEqual(verdict, .unauthorized)
    }

    // MARK: - applyReleaseUpdateAndTerminate (via applyStagedUpdateAndRelaunch + terminateApp seams)

    func testApplyReleaseUpdate_launched_logsSuccessAndTerminates() throws {
        let m = try makeVM()
        let terminated = OuroBox<Bool>(false)
        m.terminateApp = { terminated.value = true }
        m.applyStagedUpdateAndRelaunch = { _, _ in .launched }
        let staged = WorkbenchUpdateInstaller.Staged(
            appURL: URL(fileURLWithPath: "/tmp/staged.app"),
            stagingRoot: URL(fileURLWithPath: "/tmp/staging"),
            version: "9.9.9", build: "42")
        m.applyReleaseUpdateAndTerminate(staged: staged, successLog: "swapped and relaunching")
        XCTAssertTrue(m.isApplyingManualUpdate, ".launched sets the applying-manual-update flag")
        XCTAssertTrue(terminated.value, ".launched quits the app via the terminate seam")
        XCTAssertTrue(
            m.state.actionLog.contains { $0.result == "swapped and relaunching" && $0.succeeded },
            ".launched records the success action-log line")
    }

    func testApplyReleaseUpdate_failedToLaunch_restoresStateAndDoesNotTerminate() throws {
        let m = try makeVM()
        let terminated = OuroBox<Bool>(false)
        m.terminateApp = { terminated.value = true }
        m.applyStagedUpdateAndRelaunch = { _, _ in .failedToLaunch("helper missing") }
        let staged = WorkbenchUpdateInstaller.Staged(
            appURL: URL(fileURLWithPath: "/tmp/staged.app"),
            stagingRoot: URL(fileURLWithPath: "/tmp/staging"),
            version: "9.9.9", build: "42")
        m.applyReleaseUpdateAndTerminate(staged: staged, successLog: "unused")
        XCTAssertFalse(terminated.value, ".failedToLaunch must NOT quit")
        XCTAssertFalse(m.isApplyingManualUpdate, "the manual-update flag is cleared on failure")
        XCTAssertFalse(m.releaseUpdateIsInstalling, "the installing flag is cleared on failure")
        XCTAssertEqual(m.stagedUpdateVersion, "9.9.9 (build 42)", "the staged version is held for retry")
        XCTAssertEqual(m.pendingStagedUpdate?.version, "9.9.9", "the staged update is held for retry")
        XCTAssertEqual(m.releaseUpdateInstallError, "Could not start the update helper: helper missing")
        XCTAssertTrue(
            m.state.actionLog.contains { $0.result.contains("helper missing") && !$0.succeeded },
            ".failedToLaunch records the failure action-log line")
    }

    // MARK: - resetToFirstRun (via killAllPersistentScreensOnReset + relaunchAfterExitOnReset + terminateApp)

    func testResetToFirstRun_setsResettingFlag_relaunches_andTerminates() throws {
        let m = try makeVM()
        let killed = OuroBox<Bool>(false)
        let relaunched = OuroBox<Bool>(false)
        let terminated = OuroBox<Bool>(false)
        m.killAllPersistentScreensOnReset = { killed.value = true }
        m.relaunchAfterExitOnReset = { relaunched.value = true }
        m.terminateApp = { terminated.value = true }
        m.resetToFirstRun()
        XCTAssertTrue(m.isResettingToFirstRun, "the reset suppresses all further persistence")
        XCTAssertTrue(killed.value, "the reset quits live persistent screens")
        XCTAssertTrue(relaunched.value, "the reset arms the relaunch helper")
        XCTAssertTrue(terminated.value, "the reset quits the app last")
    }

    func testResetToFirstRun_wipesStateFile() throws {
        let (m, paths) = try makeVMWithPaths()
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.stateURL.path),
                      "precondition: the seeded state file exists before reset")
        m.resetToFirstRun()
        // The factory reset removes the workspace state file so the next launch bootstraps fresh.
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.stateURL.path),
                       "the reset removes the persisted workspace state")
    }

    // MARK: - runColdStartProviderCheck (via providerCheckRunner seam)
    //
    // VM-GATE FINAL FLOOR (#1): the cold-start probe was rerouted from a DIRECT
    // `Self.runProviderCheckProcess(...)` call to `providerCheckRunner(agentName, lane, 15)` (the
    // seam's DEFAULT closure IS runProviderCheckProcess, so production is byte-identical) + widened
    // private→internal. Its per-verdict fold now drives without spawning `ouro check`, exactly like
    // its already-seamed siblings runCloneProviderCheck / runOnboardingProviderCheck.

    func testColdStartProviderCheck_launchFailure_isNil() async throws {
        let m = try makeVM()
        m.providerCheckRunner = { _, _, _ in nil }
        let verdict = await m.runColdStartProviderCheck(agentName: "scout", lane: "outward")
        XCTAssertNil(verdict, "a nil runner result → nil (couldn't confirm, never a false-green)")
    }

    func testColdStartProviderCheck_timedOut_isNil() async throws {
        let m = try makeVM()
        m.providerCheckRunner = { _, _, _ in
            ProviderCheckProcessResult(timedOut: true, terminationStatus: 0, output: readyVerdictOutput)
        }
        let verdict = await m.runColdStartProviderCheck(agentName: "scout", lane: "outward")
        XCTAssertNil(verdict, "a timeout → nil even if truncated output looked ready")
    }

    func testColdStartProviderCheck_working_classifiesWorking_onShortBudget() async throws {
        let m = try makeVM()
        let captured = OuroBox<(String, String, TimeInterval)?>(nil)
        m.providerCheckRunner = { agent, lane, budget in
            captured.value = (agent, lane, budget)
            return ProviderCheckProcessResult(timedOut: false, terminationStatus: 0, output: readyVerdictOutput)
        }
        let verdict = await m.runColdStartProviderCheck(agentName: "scout", lane: "outward")
        XCTAssertEqual(verdict, .working, "a ready verdict line classifies .working")
        // mutation-verified: the seam received the agent/lane + the SHORT 15s cold-start budget.
        XCTAssertEqual(captured.value?.0, "scout")
        XCTAssertEqual(captured.value?.1, "outward")
        XCTAssertEqual(captured.value?.2, 15, "the cold-start probe uses the SHORT 15s budget")
    }

    func testColdStartProviderCheck_unauthorized_classifiesUnauthorized() async throws {
        let m = try makeVM()
        m.providerCheckRunner = { _, _, _ in
            ProviderCheckProcessResult(timedOut: false, terminationStatus: 0, output: unauthorizedVerdictOutput)
        }
        let verdict = await m.runColdStartProviderCheck(agentName: "scout", lane: "outward")
        XCTAssertEqual(verdict, .unauthorized)
    }

    // MARK: - refreshAgentOutwardReadiness (TaskGroup verdict-store + in-flight-clear fold)
    //
    // VM-GATE FINAL FLOOR (#2): the per-agent outward-readiness TaskGroup folds each
    // runColdStartProviderCheck verdict into `agentOutwardVerdicts` (when non-nil) + clears the
    // `agentChecksInFlight` flag. Unblocked by #1 routing through the seam — drive via the REAL
    // fold (not a direct verdict injection), polling the published effect.

    func testRefreshAgentOutwardReadiness_workingVerdict_storesVerdictAndClearsInFlight() async throws {
        let m = try makeVM()
        m.providerCheckRunner = { _, _, _ in
            ProviderCheckProcessResult(timedOut: false, terminationStatus: 0, output: readyVerdictOutput)
        }
        m.ouroAgents = [
            OuroAgentRecord(
                name: "scout", bundlePath: "/tmp/scout", configPath: "/tmp/scout/config.json",
                status: .ready, detail: "ready",
                humanFacing: OuroAgentLane(provider: "openai", model: "gpt-5"))
        ]
        m.refreshAgentOutwardReadiness()
        XCTAssertTrue(m.agentChecksInFlight.contains("scout"), "the target is marked in-flight up front")
        for _ in 0..<500 where m.agentOutwardVerdicts["scout"] == nil { await Task.yield() }
        XCTAssertEqual(m.agentOutwardVerdicts["scout"], .working, "the fold stores the working verdict")
        XCTAssertFalse(m.agentChecksInFlight.contains("scout"), "the fold clears the in-flight flag")
    }

    func testRefreshAgentOutwardReadiness_nilVerdict_leavesNoVerdictButClearsInFlight() async throws {
        let m = try makeVM()
        m.providerCheckRunner = { _, _, _ in nil }  // couldn't confirm → nil → no verdict stored
        m.ouroAgents = [
            OuroAgentRecord(
                name: "scout", bundlePath: "/tmp/scout", configPath: "/tmp/scout/config.json",
                status: .ready, detail: "ready",
                humanFacing: OuroAgentLane(provider: "openai", model: "gpt-5"))
        ]
        m.refreshAgentOutwardReadiness()
        for _ in 0..<500 where m.agentChecksInFlight.contains("scout") { await Task.yield() }
        XCTAssertNil(m.agentOutwardVerdicts["scout"], "a nil verdict leaves no verdict → 'not verified'")
        XCTAssertFalse(m.agentChecksInFlight.contains("scout"), "the in-flight flag is still cleared on nil")
    }

    func testRefreshAgentOutwardReadiness_noConfiguredTargets_isNoOp() throws {
        let m = try makeVM()
        // A config-ready agent with NO outward lane configured is not a probe target.
        m.ouroAgents = [
            OuroAgentRecord(
                name: "scout", bundlePath: "/tmp/scout", configPath: "/tmp/scout/config.json",
                status: .ready, detail: "ready", humanFacing: nil)
        ]
        m.refreshAgentOutwardReadiness()
        XCTAssertTrue(m.agentChecksInFlight.isEmpty, "no configured outward lane → nothing goes in-flight")
    }

    // MARK: - runOnboardingProviderChecksIfNeeded (generation/cancellation-race serialTask fold)
    //
    // VM-GATE FINAL FLOOR (#4): the serialTask runs the lanes sequentially behind per-lane
    // generation + cancellation guards, storing each awaited runOnboardingProviderCheck result into
    // `onboardingProviderChecks`. The awaited runner is already seamed (via providerCheckRunner) —
    // this drives the race-guarded store fold.

    func testRunOnboardingProviderChecksIfNeeded_readyAgent_storesPassedResult() async throws {
        let m = try makeVM(boss: "scout")
        m.providerCheckRunner = { _, _, _ in
            ProviderCheckProcessResult(timedOut: false, terminationStatus: 0, output: readyVerdictOutput)
        }
        m.ouroAgents = [
            OuroAgentRecord(
                name: "scout", bundlePath: "/tmp/scout", configPath: "/tmp/scout/config.json",
                status: .ready, detail: "ready",
                humanFacing: OuroAgentLane(provider: "openai", model: "gpt-5"),
                agentFacing: OuroAgentLane(provider: "openai", model: "gpt-5"))  // lanes collapse → outward only
        ]
        m.runOnboardingProviderChecksIfNeeded()
        // Marked running up front (the generation-stamp + running arm).
        XCTAssertEqual(m.onboardingProviderChecks["outward"]?.state, .running, "the lane is marked running up front")
        for _ in 0..<500 where m.onboardingProviderChecks["outward"]?.state == .running { await Task.yield() }
        XCTAssertEqual(m.onboardingProviderChecks["outward"]?.state, .passed,
                       "the serialTask folds the working verdict into a .passed result")
    }

    func testRunOnboardingProviderChecksIfNeeded_notReadyAgent_isNoOp() throws {
        let m = try makeVM(boss: "scout")
        m.ouroAgents = [
            OuroAgentRecord(
                name: "scout", bundlePath: "/tmp/scout", configPath: "/tmp/scout/config.json",
                status: .missingConfig, detail: "needs config",
                humanFacing: OuroAgentLane(provider: "openai", model: "gpt-5"))
        ]
        m.runOnboardingProviderChecksIfNeeded()
        XCTAssertTrue(m.onboardingProviderChecks.isEmpty, "a non-ready selected agent runs no checks")
    }

    func testRunOnboardingProviderChecksIfNeeded_alreadyPassed_skipsRecheck() throws {
        let m = try makeVM(boss: "scout")
        m.ouroAgents = [
            OuroAgentRecord(
                name: "scout", bundlePath: "/tmp/scout", configPath: "/tmp/scout/config.json",
                status: .ready, detail: "ready",
                humanFacing: OuroAgentLane(provider: "openai", model: "gpt-5"),
                agentFacing: OuroAgentLane(provider: "openai", model: "gpt-5"))
        ]
        // Seed the outward lane already passed → the collect loop's `.passed` guard skips it, and
        // with no lanes to check the method returns before stamping `.running`.
        m.onboardingProviderChecks["outward"] = OnboardingProviderCheckResult(
            lane: "outward", state: .passed, detail: "already good")
        m.runOnboardingProviderChecksIfNeeded()
        XCTAssertEqual(m.onboardingProviderChecks["outward"]?.state, .passed,
                       "an already-passed lane is not re-marked running (the no-lanes-to-check guard)")
    }

    // MARK: - scanForOnboardingSessions (post-scan candidate/proposal/log fold via the runner seam)
    //
    // VM-GATE FINAL FLOOR (#3): the scan was routed through the NEW `scanForOnboardingSessionsRunner`
    // seam (default = the real RecentSessionScanner scan, byte-identical). Inject a fake candidate
    // list to drive the post-scan fold: set-candidates → build-proposal → clear-scanning-flag →
    // recordActionLog.

    func testScanForOnboardingSessions_foldsInjectedCandidatesIntoProposal() async throws {
        let m = try makeVM()
        // The scan only runs once readiness is ready — seed a ready snapshot so the guard passes.
        m.onboardingReadiness = OnboardingReadiness(
            state: .ready, headline: "Ready", detail: "all set", selectedBossName: "boss", repairSteps: [])
        let candidate = RecentSessionCandidate(
            id: "cand-1", source: .claudeCode, agentKind: nil, title: "Recent work",
            workingDirectory: "/tmp/repo", lastActiveAt: Date(),
            resumeCommand: ["echo", "resume"], summary: "a recent session",
            evidencePaths: ["/tmp/repo/.evidence"], confidence: 0.9)
        m.scanForOnboardingSessionsRunner = { _ in [candidate] }
        let logBefore = m.state.actionLog.count
        m.scanForOnboardingSessions()
        XCTAssertTrue(m.onboardingIsScanning, "the scan sets the in-flight flag up front")
        for _ in 0..<500 where m.onboardingIsScanning { await Task.yield() }
        XCTAssertEqual(m.onboardingCandidates, [candidate], "the fold stores the scanned candidates")
        XCTAssertFalse(m.onboardingProposal?.groups.isEmpty ?? true,
                       "the fold builds a non-empty proposal from the candidates")
        XCTAssertEqual(m.state.actionLog.count, logBefore + 1, "the fold records ONE action-log entry")
        XCTAssertEqual(m.state.actionLog.first?.action, "scanOnboardingSessions")
        XCTAssertTrue(m.state.actionLog.first?.result.contains("1 recent session") ?? false,
                      "the log reports the candidate count")
    }

    func testScanForOnboardingSessions_notReady_refreshesAndDoesNotScan() throws {
        let m = try makeVM()
        m.onboardingReadiness = OnboardingReadiness(
            state: .needsCredentials, headline: "Connect", detail: "needs credentials",
            selectedBossName: "boss", repairSteps: [])
        let scanned = OuroBox<Bool>(false)
        m.scanForOnboardingSessionsRunner = { _ in scanned.value = true; return [] }
        m.scanForOnboardingSessions()
        XCTAssertFalse(m.onboardingIsScanning, "a not-ready readiness routes to refresh, never scans")
        XCTAssertFalse(scanned.value, "the runner seam is not invoked when readiness is not ready")
    }

    func testScanForOnboardingSessions_alreadyScanning_isNoOp() throws {
        let m = try makeVM()
        m.onboardingIsScanning = true
        let scanned = OuroBox<Bool>(false)
        m.scanForOnboardingSessionsRunner = { _ in scanned.value = true; return [] }
        m.scanForOnboardingSessions()
        XCTAssertFalse(scanned.value, "the already-scanning guard returns before invoking the runner")
    }
}

/// A tiny lock-protected box for capturing seam invocations across `@Sendable` closures.
private final class OuroBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ initial: T) { _value = initial }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

/// `ready` / `failed` verdict lines in the shape `ProviderCheckClassifier` parses
/// (`<agent> <lane> <provider> / <model>: <status>`). Free functions so the `@Sendable`
/// provider-check seam closures can use them without capturing the `@MainActor` test class.
private let readyVerdictOutput = "scout main openai / gpt-5: ready"
private let unauthorizedVerdictOutput = "scout main openai / gpt-5: failed (401 unauthorized)"
// `unknown (… vault …)` routes through classifyUnknown → .vaultLocked; `failed (fetch failed)`
// routes through matchesUnreachable → .unreachable.
private let vaultLockedVerdictOutput = "scout main openai / gpt-5: unknown (vault locked)"
private let unreachableVerdictOutput = "scout main openai / gpt-5: failed (fetch failed)"
#endif
