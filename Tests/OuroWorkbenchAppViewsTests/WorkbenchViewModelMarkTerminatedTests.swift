#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 5 — the exit/attention reconciliation machinery:
/// `markTerminated(entryId:runId:rawStatus:)` (`:9643`) and its tightly-coupled helpers
/// `applyAttentionSignal` (`:9591`), `shouldPostExitNotification` (`:9755`), and the
/// `postUnexpectedExitNotification` param-composition (`:9770`, driven up to the
/// `UNUserNotificationCenter.requestAuthorization` boundary). These are state-transition logic:
/// every arm of `markTerminated` (early-guard / detached-persistent / current-session idle exit /
/// manualActionNeeded exit / screen-127 diagnosis / manually-terminated / non-current run) is
/// INVOKE-able + effect-asserted (the run status + entry attention + summary + activeSessions
/// removal) + mutation-verified. The live `screen -ls` subprocess is the genuine-machinery boundary,
/// driven up to the syscall via the `persistentSessionLister` closure seam (default = the real
/// `persistentSessionIsListed`); only the literal subprocess inside that default closure carves.
/// The UNUserNotificationCenter authorization callback bodies stay carved (system permission UI).
@MainActor
final class WorkbenchViewModelMarkTerminatedTests: XCTestCase {

    private static let projectId = UUID(uuidString: "C0AC7E12-0000-0000-0000-0000000000A1")!
    private static let entryId = UUID(uuidString: "C0AC7E12-0000-0000-0000-0000000000E1")!
    private static let wsId = UUID(uuidString: "C0AC7E12-0000-0000-0000-0000000000B1")!
    private static let runId = UUID(uuidString: "C0AC7E12-0000-0000-0000-0000000000F1")!

    // MARK: - Hermetic VM with one entry + one running run

    private func makeVM(
        entries: [ProcessEntry],
        runs: [ProcessRun]
    ) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmterm-\(UUID().uuidString)", isDirectory: true)
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
        m.launchTerminalSession = { _ in }   // no real screen child (#332)
        // The detached-vs-crash decision's live `screen -ls` subprocess is the carved boundary;
        // default it to "not listed" so no test accidentally spawns `screen`.
        m.persistentSessionLister = { _ in false }
        // The exit notification touches UNUserNotificationCenter (traps in headless xctest:
        // "bundleProxyForCurrentProcess is nil"); record the decision instead of posting. The
        // seam runs on the main actor; record into a fresh per-VM box (no cross-isolation capture).
        let recorder = NotificationRecorder()
        notifications = recorder
        m.postExitNotification = { name, code, needs in
            recorder.posted.append((name, code, needs))
        }
        return m
    }

    /// A reference recorder for the `postExitNotification` seam — the VM only ever invokes the
    /// seam on the main actor, so the box is touched single-threaded; capturing it (not `self`)
    /// keeps the recording closure free of any cross-actor capture.
    @MainActor
    private final class NotificationRecorder {
        var posted: [(name: String, exitCode: Int32?, needsAttention: Bool)] = []
    }
    private var notifications: NotificationRecorder?
    private var postedNotifications: [(name: String, exitCode: Int32?, needsAttention: Bool)] {
        notifications?.posted ?? []
    }

    private func entry(attention: AttentionState = .active, isArchived: Bool = false) -> ProcessEntry {
        var e = ProcessEntry(
            id: Self.entryId, projectId: Self.projectId, name: "build", kind: .shell,
            executable: "/bin/zsh", workingDirectory: "/tmp/vmterm",
            trust: .trusted, autoResume: false, isArchived: isArchived)
        e.attention = attention
        return e
    }

    private func runningRun() -> ProcessRun {
        ProcessRun(id: Self.runId, entryId: Self.entryId, status: .running)
    }

    /// Register an (un-started, no-PTY) controller in `activeSessions` so the live-session arms
    /// (`isCurrentSession`) take their live branch. The plan's runId matches the running run.
    ///
    /// NOTE: the VM's `init` → `load()` runs `StartupRecoveryReconciler.reconcile` synchronously,
    /// which sees the seeded `.running` run with NO live session AT LOAD TIME and rewrites it to
    /// `.needsRecovery` (a "lost while closed" survivor). markTerminated's `status == .running`
    /// guard would then return early. So we re-seed the run to `.running` here — the post-load
    /// state a live, attached session actually has — to honestly model "a running session exits".
    @discardableResult
    private func registerLive(
        _ m: WorkbenchViewModel,
        recoveryAction: RecoveryAction? = nil,
        persistentSessionName: String? = nil
    ) throws -> TerminalSessionController {
        if let idx = m.state.processRuns.firstIndex(where: { $0.id == Self.runId }) {
            m.state.processRuns[idx].status = .running
        }
        let plan = TerminalCommandPlan(
            entryId: Self.entryId, runId: Self.runId, executable: "/bin/zsh", arguments: [],
            workingDirectory: "/tmp/vmterm", recoveryAction: recoveryAction,
            persistentSessionName: persistentSessionName, reason: "vmterm test")
        let controller = try TerminalSessionController(
            plan: plan, onStarted: { _ in }, onOutput: {}, onTerminated: { _ in })
        m.activeSessions[Self.entryId] = controller
        return controller
    }

    private func run(in m: WorkbenchViewModel) -> ProcessRun? {
        m.state.processRuns.first { $0.id == Self.runId }
    }

    /// Re-seed the entry's attention AFTER init (the load-time reconciler may have perturbed it),
    /// so an applyAttentionSignal test starts from the exact state it intends to exercise.
    private func seedAttention(_ m: WorkbenchViewModel, _ attention: AttentionState) {
        if let idx = m.state.processEntries.firstIndex(where: { $0.id == Self.entryId }) {
            m.state.processEntries[idx].attention = attention
        }
    }

    private func entryNow(in m: WorkbenchViewModel) -> ProcessEntry? {
        m.state.processEntries.first { $0.id == Self.entryId }
    }

    // MARK: - markTerminated early guards

    func testMarkTerminated_noMatchingRun_isNoOp() throws {
        let m = try makeVM(entries: [entry()], runs: [])   // no run at all
        m.markTerminated(entryId: Self.entryId, runId: Self.runId, rawStatus: 0)
        XCTAssertTrue(m.state.processRuns.isEmpty, "no matching run → the guard returns, nothing written")
    }

    func testMarkTerminated_runNotRunning_isNoOp() throws {
        // A run that already exited: the `status == .running` guard returns early.
        var r = runningRun()
        r.status = .exited
        let m = try makeVM(entries: [entry()], runs: [r])
        m.markTerminated(entryId: Self.entryId, runId: Self.runId, rawStatus: 0)
        XCTAssertEqual(run(in: m)?.status, .exited, "already-exited run is left untouched")
    }

    // MARK: - markTerminated current-session clean exit (idle)

    func testMarkTerminated_currentSession_cleanExit_setsIdleAndRemovesSession() throws {
        let m = try makeVM(entries: [entry()], runs: [runningRun()])
        try registerLive(m)
        XCTAssertNotNil(m.activeSessions[Self.entryId], "precondition: live session registered")
        // rawStatus 0 → exitCode 0 → clean exit; no recoveryAction → .exited, attention .idle.
        m.markTerminated(entryId: Self.entryId, runId: Self.runId, rawStatus: 0)
        XCTAssertEqual(run(in: m)?.status, .exited, "clean current-session exit → run .exited")
        XCTAssertEqual(run(in: m)?.exitCode, 0)
        XCTAssertEqual(entryNow(in: m)?.attention, .idle, "clean exit → idle (not needsBossReview)")
        XCTAssertNil(m.activeSessions[Self.entryId], "the live session is cleared")
        XCTAssertEqual(entryNow(in: m)?.lastSummary, "build exited with code 0")
    }

    func testMarkTerminated_clearsTerminalFocusWhenFocused() throws {
        let m = try makeVM(entries: [entry()], runs: [runningRun()])
        try registerLive(m)
        m.terminalFocusEntryID = Self.entryId
        m.markTerminated(entryId: Self.entryId, runId: Self.runId, rawStatus: 0)
        XCTAssertNil(m.terminalFocusEntryID, "the focused-on entry's focus is released when its session ends")
    }

    // MARK: - markTerminated manualActionNeeded (recovery couldn't auto-resume)

    func testMarkTerminated_autoResumeRecovery_nonZero_needsBossReview() throws {
        let m = try makeVM(entries: [entry()], runs: [runningRun()])
        try registerLive(m, recoveryAction: .autoResume)
        // rawStatus 0x100 (1<<8) → exitCode 1 (non-zero); autoResume + !manual → manualActionNeeded.
        m.markTerminated(entryId: Self.entryId, runId: Self.runId, rawStatus: 0x100)
        XCTAssertEqual(run(in: m)?.status, .manualActionNeeded, "autoResume recovery exit → manualActionNeeded")
        XCTAssertEqual(entryNow(in: m)?.attention, .needsBossReview, "manualActionNeeded → needsBossReview")
        XCTAssertEqual(entryNow(in: m)?.lastSummary, "build recovery attempt exited with code 1")
        // The non-clean exit posts a notification flagged needsAttention (manualActionNeeded).
        XCTAssertEqual(postedNotifications.count, 1, "a non-zero exit posts an unexpected-exit notification")
        XCTAssertEqual(postedNotifications.first?.name, "build")
        XCTAssertEqual(postedNotifications.first?.exitCode, 1)
        XCTAssertTrue(postedNotifications.first?.needsAttention == true,
                      "manualActionNeeded → the notification is flagged needs-attention")
    }

    // MARK: - markTerminated notification decision (whether / throttle)

    func testMarkTerminated_cleanExit_postsNoNotification() throws {
        let m = try makeVM(entries: [entry()], runs: [runningRun()])
        try registerLive(m)
        m.markTerminated(entryId: Self.entryId, runId: Self.runId, rawStatus: 0)
        XCTAssertTrue(postedNotifications.isEmpty, "a clean (code-0) exit posts no notification")
    }

    func testMarkTerminated_signalExit_postsNotificationWithNilCode() throws {
        // rawStatus nil → exitCode nil (a signal kill, not a clean exit) → notification posted.
        let m = try makeVM(entries: [entry()], runs: [runningRun()])
        try registerLive(m)
        m.markTerminated(entryId: Self.entryId, runId: Self.runId, rawStatus: nil)
        XCTAssertEqual(postedNotifications.count, 1, "a signal exit (nil code) is unexpected → notify")
        XCTAssertNil(postedNotifications.first?.exitCode, "a signal exit carries no exit code")
        XCTAssertFalse(postedNotifications.first?.needsAttention == true,
                       "no recoveryAction → .exited → not flagged needs-attention")
    }

    func testMarkTerminated_throttlesRepeatNotificationsPerEntry() throws {
        // Two non-clean exits for the SAME entry inside the throttle window → only the FIRST posts.
        let m = try makeVM(entries: [entry()], runs: [runningRun()])
        try registerLive(m)
        m.markTerminated(entryId: Self.entryId, runId: Self.runId, rawStatus: 0x100)
        XCTAssertEqual(postedNotifications.count, 1, "first non-clean exit posts")
        // Re-arm a running run + live session, then exit again immediately.
        try registerLive(m)
        m.markTerminated(entryId: Self.entryId, runId: Self.runId, rawStatus: 0x100)
        XCTAssertEqual(postedNotifications.count, 1,
                       "a second exit inside the throttle window is suppressed (shouldPostExitNotification)")
    }

    // MARK: - markTerminated folds a pending coalesced output timestamp (applyPendingOutput)

    func testMarkTerminated_foldsPendingOutputTimestampIntoExitingRun() throws {
        let m = try makeVM(entries: [entry()], runs: [runningRun()])
        try registerLive(m)
        // Stash a coalesced output timestamp for this run (the debounce path), then exit it:
        // markTerminated calls applyPendingOutput first, which must fold that timestamp into the
        // run's lastOutputAt before rewriting the status (so the final freshness isn't lost).
        XCTAssertNil(run(in: m)?.lastOutputAt, "precondition: no recorded output yet")
        m.markOutput(entryId: Self.entryId, runId: Self.runId)
        m.markTerminated(entryId: Self.entryId, runId: Self.runId, rawStatus: 0)
        XCTAssertNotNil(run(in: m)?.lastOutputAt,
                        "the pending output timestamp is folded into the exiting run (applyPendingOutput)")
        XCTAssertEqual(run(in: m)?.status, .exited)
    }

    // MARK: - markTerminated screen-wrapped 127 diagnosis

    func testMarkTerminated_screenWrapped127_usesDiagnosisSummary() throws {
        let m = try makeVM(entries: [entry()], runs: [runningRun()])
        try registerLive(m, persistentSessionName: "ouro-build")
        // exit 127 (0x7f00) on a screen-wrapped session → the TerminalExitDiagnosis summary.
        m.markTerminated(entryId: Self.entryId, runId: Self.runId, rawStatus: 0x7f00)
        XCTAssertEqual(run(in: m)?.status, .exited)
        XCTAssertEqual(run(in: m)?.exitCode, 127)
        let summary = entryNow(in: m)?.lastSummary ?? ""
        XCTAssertTrue(summary.hasPrefix("build: "),
                      "screen-wrapped 127 → the diagnosis summary, not the bare exit line: \(summary)")
        XCTAssertNotEqual(summary, "build exited with code 127", "the diagnosis branch, not the plain branch")
    }

    // MARK: - markTerminated detached-persistent (screen still listed) — via the lister seam

    func testMarkTerminated_detachedPersistent_setsNeedsRecovery() throws {
        let m = try makeVM(entries: [entry()], runs: [runningRun()])
        try registerLive(m, persistentSessionName: "ouro-build")
        m.persistentSessionLister = { name in
            XCTAssertEqual(name, "ouro-build", "the lister is asked about the plan's screen session name")
            return true   // the screen session is STILL listed → detached, not crashed
        }
        m.markTerminated(entryId: Self.entryId, runId: Self.runId, rawStatus: 0)
        XCTAssertEqual(run(in: m)?.status, .needsRecovery, "detached persistent session → run .needsRecovery")
        XCTAssertNil(run(in: m)?.exitCode, "the detached branch clears the exit code")
        XCTAssertEqual(entryNow(in: m)?.attention, .needsBossReview)
        XCTAssertEqual(entryNow(in: m)?.lastSummary,
                       "build detached; recovery can reattach the persistent terminal session")
        XCTAssertNil(m.activeSessions[Self.entryId], "the live client is cleared on detach")
    }

    // MARK: - markTerminated manually-terminated (via terminate())

    func testMarkTerminated_manuallyTerminated_exitsIdleNoNotification() throws {
        let m = try makeVM(entries: [entry()], runs: [runningRun()])
        try registerLive(m)   // no persistentSessionName → terminate() spawns no screen quit
        let e = try XCTUnwrap(entryNow(in: m))
        m.terminate(e)   // inserts runId into manuallyTerminatedRunIDs, then markTerminated(rawStatus: nil)
        XCTAssertEqual(run(in: m)?.status, .exited, "manually-terminated (no recoveryAction) → .exited")
        XCTAssertEqual(entryNow(in: m)?.attention, .idle, "a deliberate stop → idle, never needsBossReview")
        XCTAssertNil(m.activeSessions[Self.entryId])
        XCTAssertTrue(m.state.actionLog.contains { $0.action == "stopSession" }, "the stop is audit-logged")
    }

    // MARK: - markTerminated non-current run (a stale run id, not the live session's)

    func testMarkTerminated_nonCurrentRun_updatesRunButKeepsLiveSession() throws {
        // A second, older run for the same entry that is NOT the live session's runId.
        let staleRunId = UUID(uuidString: "C0AC7E12-0000-0000-0000-0000000000F2")!
        let staleRun = ProcessRun(id: staleRunId, entryId: Self.entryId, status: .running)
        let m = try makeVM(entries: [entry()], runs: [runningRun(), staleRun])
        try registerLive(m)   // live session is on Self.runId, NOT staleRunId
        // The load-time reconciler rewrote the stale (no-live-session) run to .needsRecovery;
        // re-seed it .running so markTerminated's status guard takes the live arm.
        if let idx = m.state.processRuns.firstIndex(where: { $0.id == staleRunId }) {
            m.state.processRuns[idx].status = .running
        }
        m.markTerminated(entryId: Self.entryId, runId: staleRunId, rawStatus: 0)
        XCTAssertEqual(m.state.processRuns.first { $0.id == staleRunId }?.status, .exited,
                       "the stale run is marked exited")
        XCTAssertNotNil(m.activeSessions[Self.entryId],
                        "but the live session (a different runId) is untouched — not the current run")
    }

    // MARK: - applyAttentionSignal (all signal arms + guards)

    private func classification(_ signal: AttentionSignal, reason: String? = "why") -> AttentionClassification {
        AttentionClassification(signal: signal, reason: reason)
    }

    func testApplyAttentionSignal_waitingOnHuman_fromActive_setsWaiting() throws {
        let m = try makeVM(entries: [entry(attention: .active)], runs: [runningRun()])
        try registerLive(m)
        seedAttention(m, .active)
        m.applyAttentionSignal(classification(.waitingOnHuman), entryId: Self.entryId, runId: Self.runId)
        XCTAssertEqual(entryNow(in: m)?.attention, .waitingOnHuman)
        XCTAssertEqual(entryNow(in: m)?.attentionReason, "why")
    }

    func testApplyAttentionSignal_blocked_fromIdle_setsBlocked() throws {
        let m = try makeVM(entries: [entry(attention: .idle)], runs: [runningRun()])
        try registerLive(m)
        seedAttention(m, .idle)
        m.applyAttentionSignal(classification(.blocked), entryId: Self.entryId, runId: Self.runId)
        XCTAssertEqual(entryNow(in: m)?.attention, .blocked)
    }

    func testApplyAttentionSignal_unknown_clearsStaleWaiting() throws {
        let m = try makeVM(entries: [entry(attention: .waitingOnHuman)], runs: [runningRun()])
        try registerLive(m)
        seedAttention(m, .waitingOnHuman)
        m.applyAttentionSignal(classification(.unknown, reason: nil), entryId: Self.entryId, runId: Self.runId)
        XCTAssertEqual(entryNow(in: m)?.attention, .active, "unknown clears a stale wait back to active")
        XCTAssertNil(entryNow(in: m)?.attentionReason)
    }

    func testApplyAttentionSignal_waitingOnHuman_fromBossReview_isGuarded() throws {
        // Only active/idle escalate to waiting; a boss-set review state is NOT overridden.
        let m = try makeVM(entries: [entry(attention: .needsBossReview)], runs: [runningRun()])
        try registerLive(m)
        seedAttention(m, .needsBossReview)
        m.applyAttentionSignal(classification(.waitingOnHuman), entryId: Self.entryId, runId: Self.runId)
        XCTAssertEqual(entryNow(in: m)?.attention, .needsBossReview, "the review state is preserved")
    }

    func testApplyAttentionSignal_unknown_fromActive_isGuarded() throws {
        // unknown only clears a stale waiting/blocked; an already-active session is untouched.
        let m = try makeVM(entries: [entry(attention: .active)], runs: [runningRun()])
        try registerLive(m)
        seedAttention(m, .active)
        m.applyAttentionSignal(classification(.unknown), entryId: Self.entryId, runId: Self.runId)
        XCTAssertEqual(entryNow(in: m)?.attention, .active, "active is left as-is by an unknown signal")
    }

    func testApplyAttentionSignal_runIdMismatch_isNoOp() throws {
        let m = try makeVM(entries: [entry(attention: .active)], runs: [runningRun()])
        try registerLive(m)
        seedAttention(m, .active)
        let otherRun = UUID(uuidString: "C0AC7E12-0000-0000-0000-0000000000F9")!
        m.applyAttentionSignal(classification(.waitingOnHuman), entryId: Self.entryId, runId: otherRun)
        XCTAssertEqual(entryNow(in: m)?.attention, .active, "a signal for a non-current run is dropped")
    }

    func testApplyAttentionSignal_archivedEntry_isNoOp() throws {
        let m = try makeVM(entries: [entry(attention: .active, isArchived: true)], runs: [runningRun()])
        try registerLive(m)
        seedAttention(m, .active)
        m.applyAttentionSignal(classification(.waitingOnHuman), entryId: Self.entryId, runId: Self.runId)
        XCTAssertEqual(entryNow(in: m)?.attention, .active, "an archived entry is never re-flagged")
    }

    // MARK: - Negative controls (mutation-verified)

    func testNegativeControl_cleanExitMarksExited() throws {
        // markTerminated on a clean current-session exit MUST set .exited. A no-op body leaves
        // it .running → RED.
        let m = try makeVM(entries: [entry()], runs: [runningRun()])
        try registerLive(m)
        m.markTerminated(entryId: Self.entryId, runId: Self.runId, rawStatus: 0)
        XCTAssertEqual(run(in: m)?.status, .exited)
    }

    func testNegativeControl_detachedSetsNeedsRecovery() throws {
        // The detached branch MUST set .needsRecovery (not .exited). Routing through the crash
        // branch instead would leave .exited → RED.
        let m = try makeVM(entries: [entry()], runs: [runningRun()])
        try registerLive(m, persistentSessionName: "ouro-build")
        m.persistentSessionLister = { _ in true }
        m.markTerminated(entryId: Self.entryId, runId: Self.runId, rawStatus: 0)
        XCTAssertEqual(run(in: m)?.status, .needsRecovery)
    }
}
#endif
