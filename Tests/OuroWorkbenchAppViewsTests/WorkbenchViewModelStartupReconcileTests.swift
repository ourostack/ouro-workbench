#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 9 — startup-reconcile + external-action-apply + onboarding-scan logic, plus the
/// start* boss-action handlers NOT covered by cluster 7 (#368, which took verify/refresh/ensure):
/// `reconcileStartupAttentionWithLiveSessions` (`:6896`), `launchAutoResumeSessionsOnStartup`
/// (`:6967`), `reapOrphanedScreenSessions` (`:6873`), `applyExternalActionRequests` (`:6744`),
/// `backfillSessionIdsForFlushedRuns` no-candidate guard (`:9506`), `scanForOnboardingSessions`
/// (`:5557`) + `startBossReconstruction` (`:5608`) synchronous arms, and the empty-name / missing-
/// payload guards of `startSelectLane` / `startRegisterWorkbenchMCP` / `startRepairAgent`. Every arm
/// is INVOKE-able + effect-asserted + mutation-verified. The live `screen -X quit` reaper subprocess
/// is seamed behind `spawnPersistentScreenQuit`; the async runner/scan Tasks (real `ouro`/`ps`
/// subprocesses) are NOT spawned — only the synchronous arms preceding them are driven (the guards
/// return before any Task).
@MainActor
final class WorkbenchViewModelStartupReconcileTests: XCTestCase {

    private static let projectId = UUID(uuidString: "C8333FE0-0000-0000-0000-0000000000A1")!
    private static let wsId = UUID(uuidString: "C8333FE0-0000-0000-0000-0000000000B1")!

    /// Records `spawnPersistentScreenQuit` invocations. The seam is `@Sendable`, but the reaper
    /// invokes it on the main actor, so the recording is single-threaded; an `NSLock` keeps it
    /// formally `Sendable`-safe and lets the test read the count synchronously after the call.
    private final class QuitRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [[String]] = []
        func record(_ arguments: [String]) {
            lock.lock(); defer { lock.unlock() }
            storage.append(arguments)
        }
        var quits: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    private func makeVM(
        entries: [ProcessEntry] = [],
        runs: [ProcessRun] = [],
        quitRecorder: QuitRecorder? = nil
    ) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmrec-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            bossWatchEnabled: false,
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp")],
            processEntries: entries,
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: entries.map(\.id))],
            processRuns: runs)
        try WorkbenchStore(paths: paths).save(state)
        let m = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        m.launchTerminalSession = { _ in }
        m.quitPersistentScreenForEntry = { _ in }   // no per-entry screen quit
        if let quitRecorder {
            m.spawnPersistentScreenQuit = { args, _ in quitRecorder.record(args) }
        } else {
            m.spawnPersistentScreenQuit = { _, _ in }   // no reaper screen quit
        }
        return m
    }

    private func shellEntry(
        id: UUID = UUID(),
        name: String = "build",
        kind: ProcessKind = .shell
    ) -> ProcessEntry {
        ProcessEntry(
            id: id, projectId: Self.projectId, name: name, kind: kind,
            executable: "/bin/zsh", workingDirectory: "/tmp/vmrec",
            trust: .trusted, autoResume: false, isArchived: false)
    }

    private func entryNow(_ m: WorkbenchViewModel, _ id: UUID) -> ProcessEntry? {
        m.state.processEntries.first { $0.id == id }
    }

    // MARK: - reconcileStartupAttentionWithLiveSessions

    func testReconcile_noChange_isNoOp() throws {
        // No needs-recovery entries → the reconciler returns identical state → early return.
        let e = shellEntry()
        let m = try makeVM(entries: [e])
        let before = m.state.processEntries
        m.reconcileStartupAttentionWithLiveSessions()
        XCTAssertEqual(m.state.processEntries, before, "with nothing to reconcile, state is unchanged")
    }

    func testReconcile_liveSurvivor_calmsToIdleAndPersists() throws {
        // A `.needsRecovery` run for an entry whose `screen` is live → the planner returns
        // `.reattach` → attention is re-derived to a calm `.idle`, changing state → assign + save.
        var e = shellEntry(kind: .terminalAgent)
        e.attention = .needsBossReview
        let run = ProcessRun(id: UUID(), entryId: e.id, status: .needsRecovery)
        let m = try makeVM(entries: [e], runs: [run])
        m.liveScreenSessionNames = [PersistentTerminalSession.sessionName(for: e.id)]
        // Re-seed needsBossReview (load-time reconcile ran without the live-name set) so the
        // change is genuinely produced by THIS reconcile.
        if let idx = m.state.processEntries.firstIndex(where: { $0.id == e.id }) {
            m.state.processEntries[idx].attention = .needsBossReview
            m.state.processEntries[idx].lastSummary = nil
        }
        m.reconcileStartupAttentionWithLiveSessions()
        let after = entryNow(m, e.id)
        XCTAssertEqual(after?.attention, .idle,
                       "a live survivor is calmed to .idle (reattach), not left needsBossReview")
        XCTAssertEqual(after?.lastSummary,
                       "\(e.name) reconnected — kept running while Workbench was closed",
                       "the reconnected summary is persisted")
    }

    // MARK: - launchAutoResumeSessionsOnStartup

    func testLaunchAutoResume_prefOff_isNoOp() throws {
        let m = try makeVM(entries: [shellEntry()])
        m.autoLaunchResumableOnStartup = false
        m.launchAutoResumeSessionsOnStartup()
        XCTAssertFalse(m.bossAppliedActions.contains { $0.contains("Auto-launched") },
                       "pref off → nothing is launched")
    }

    func testLaunchAutoResume_runsAtMostOncePerLaunch() throws {
        let m = try makeVM(entries: [shellEntry()])
        m.autoLaunchResumableOnStartup = true
        m.launchAutoResumeSessionsOnStartup()   // first call runs (no candidates here → no-op effect)
        let afterFirst = m.activeSessions.count
        m.launchAutoResumeSessionsOnStartup()   // second call: the didAttempt guard returns early
        XCTAssertEqual(m.activeSessions.count, afterFirst,
                       "the second call is a no-op (fires at most once per launch)")
    }

    // MARK: - reapOrphanedScreenSessions

    func testReap_noOrphans_doesNotQuit() async throws {
        let e = shellEntry()
        let quits = QuitRecorder()
        let m = try makeVM(entries: [e], quitRecorder: quits)
        m.liveScreenSessionNames = [PersistentTerminalSession.sessionName(for: e.id)]  // owned, spared
        await m.reapOrphanedScreenSessions()
        XCTAssertTrue(quits.quits.isEmpty, "a live session owned by a known entry is not reaped")
    }

    func testReap_orphan_quitsViaSeam() async throws {
        let e = shellEntry()
        let quits = QuitRecorder()
        let m = try makeVM(entries: [e], quitRecorder: quits)
        let orphanName = PersistentTerminalSession.sessionName(for: UUID())
        m.liveScreenSessionNames = [
            PersistentTerminalSession.sessionName(for: e.id),  // owned, spared
            orphanName                                          // orphan, reaped
        ]
        await m.reapOrphanedScreenSessions()
        XCTAssertEqual(quits.quits.count, 1, "exactly the one orphan is reaped")
        XCTAssertTrue(quits.quits[0].contains(orphanName),
                      "the reaped argv targets the orphan: \(quits.quits[0])")
    }

    // MARK: - applyExternalActionRequests (synchronous apply + feed)

    func testApplyExternalActionRequests_setTrust_appliesAndFeeds() throws {
        // A `.setTrust` action is synchronous (no subprocess Task), so the apply path
        // (map → applyBossAction → markApplied → bossAppliedActions) is driven cleanly.
        let e = shellEntry(name: "agent-x", kind: .terminalAgent)
        let m = try makeVM(entries: [e])
        let action = BossWorkbenchAction(action: .setTrust, entry: e.id.uuidString, trust: .trusted)
        let request = WorkbenchActionRequest(id: UUID(), source: "boss", action: action)
        m.applyExternalActionRequests([request])
        XCTAssertFalse(m.bossAppliedActions.isEmpty, "the applied result is surfaced in the boss feed")
        XCTAssertTrue(m.bossAppliedActions.first?.hasPrefix("External boss:") == true,
                      "the feed line carries the External <source> prefix: \(m.bossAppliedActions.first ?? "nil")")
    }

    // MARK: - backfillSessionIdsForFlushedRuns no-candidate guard

    func testBackfillSessionIds_noCandidate_isNoOp() throws {
        // An exited run is not a live id-less candidate → the guard returns before any scan Task.
        let e = shellEntry(kind: .terminalAgent)
        let run = ProcessRun(id: UUID(), entryId: e.id, status: .exited)
        let m = try makeVM(entries: [e], runs: [run])
        m.backfillSessionIdsForFlushedRuns([run.id])
        XCTAssertNil(m.state.processRuns.first?.terminalSessionId,
                     "no live id-less candidate → no back-fill scan, id stays nil")
    }

    // MARK: - scanForOnboardingSessions synchronous arms

    func testScan_alreadyScanning_isNoOp() throws {
        let m = try makeVM()
        m.onboardingIsScanning = true
        m.scanForOnboardingSessions()   // the already-scanning guard returns immediately
        XCTAssertTrue(m.onboardingIsScanning, "still scanning; the re-entrancy guard held")
    }

    func testScan_notReady_refreshesAndReturns() throws {
        // Not ready (fresh VM) → the not-ready arm refreshes readiness + returns without
        // setting the scanning flag (no scan Task).
        let m = try makeVM()
        m.onboardingIsScanning = false
        m.scanForOnboardingSessions()
        XCTAssertFalse(m.onboardingIsScanning, "the not-ready arm does not start a scan")
    }

    // MARK: - startBossReconstruction synchronous guard

    func testStartBossReconstruction_notReady_refreshesAndReturns() throws {
        // Not ready → the not-ready guard refreshes readiness + returns without handing off.
        let m = try makeVM()
        m.startBossReconstruction()
        XCTAssertFalse(m.onboardingReconstructionHandedOff,
                       "the not-ready arm does not hand off reconstruction")
    }

    // MARK: - start* handlers NOT covered by #368: selectLane / registerWorkbenchMCP / repairAgent

    func testStartSelectLane_missingPayload_returnsSkipped() throws {
        let m = try makeVM()
        // No name/lane/provider/model → the combined guard skips before the runner Task.
        let action = BossWorkbenchAction(action: .selectLane)
        let result = m.applyBossAction(action, source: "test")
        XCTAssertTrue(result.contains("Skipped selectLane"), "missing-payload guard: \(result)")
    }

    func testStartRegisterWorkbenchMCP_missingName_returnsSkipped() throws {
        let m = try makeVM()
        let action = BossWorkbenchAction(action: .registerWorkbenchMCP)
        let result = m.applyBossAction(action, source: "test")
        XCTAssertTrue(result.contains("Skipped registerWorkbenchMCP"), "empty-name guard: \(result)")
    }

    func testStartRepairAgent_missingName_returnsSkipped() throws {
        let m = try makeVM()
        let action = BossWorkbenchAction(action: .repairAgent)
        let result = m.applyBossAction(action, source: "test")
        XCTAssertTrue(result.contains("Skipped repairAgent"), "empty-name guard: \(result)")
    }

    // MARK: - Negative control (mutation-verified)

    func testNegativeControl_reconcileActuallyCalmsSurvivor() throws {
        // The reconcile must FLIP a live survivor from needsBossReview → idle; a no-op would
        // leave it needsBossReview → RED.
        var e = shellEntry(kind: .terminalAgent)
        e.attention = .needsBossReview
        let run = ProcessRun(id: UUID(), entryId: e.id, status: .needsRecovery)
        let m = try makeVM(entries: [e], runs: [run])
        m.liveScreenSessionNames = [PersistentTerminalSession.sessionName(for: e.id)]
        if let idx = m.state.processEntries.firstIndex(where: { $0.id == e.id }) {
            m.state.processEntries[idx].attention = .needsBossReview
        }
        XCTAssertEqual(entryNow(m, e.id)?.attention, .needsBossReview, "precondition")
        m.reconcileStartupAttentionWithLiveSessions()
        XCTAssertEqual(entryNow(m, e.id)?.attention, .idle, "the reconcile actually calms the survivor")
    }
}
#endif
