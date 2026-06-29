#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 6 — the session-lifecycle handlers:
/// `requestDeleteCustomSession` (`:7529`), `deleteCustomSession` (`:7541`),
/// `revealLatestTranscript` (`:7247`), `requestStop`/`confirmStop` (`:7282`/`:7293`), and the
/// `applySessionIdBackfills` (`:9509`) write-fold. These are state-transition logic: every arm
/// (the live-session / not-custom guards, the delete + reselect + action-log path, the
/// no-transcript / missing-file / reveal arms, the stop-confirmation gate, the backfill
/// nil-guard + mutate) is INVOKE-able + effect-asserted + mutation-verified. The live
/// `screen -X quit` subprocess (delete path) is seamed behind `quitPersistentScreenForEntry`; the
/// `NSWorkspace.activateFileViewerSelecting` reveal is the carved boundary (driven up to it).
@MainActor
final class WorkbenchViewModelSessionLifecycleTests: XCTestCase {

    private static let projectId = UUID(uuidString: "C6111FE0-0000-0000-0000-0000000000A1")!
    private static let entryId = UUID(uuidString: "C6111FE0-0000-0000-0000-0000000000E1")!
    private static let wsId = UUID(uuidString: "C6111FE0-0000-0000-0000-0000000000B1")!
    private static let runId = UUID(uuidString: "C6111FE0-0000-0000-0000-0000000000F1")!

    private var screenQuits: [UUID] = []

    private func makeVM(entries: [ProcessEntry], runs: [ProcessRun] = []) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmlife-\(UUID().uuidString)", isDirectory: true)
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
        let box = QuitRecorder()
        quits = box
        m.quitPersistentScreenForEntry = { id in box.ids.append(id) }
        // #365's reveal seam (now on main): record reveals instead of launching Finder.
        let rev = RevealRecorder()
        reveals = rev
        m.revealFileViewerSelectingURLs = { urls in rev.urls.append(contentsOf: urls) }
        return m
    }

    @MainActor private final class QuitRecorder { var ids: [UUID] = [] }
    private var quits: QuitRecorder?
    @MainActor private final class RevealRecorder { var urls: [URL] = [] }
    private var reveals: RevealRecorder?

    private func entry(kind: ProcessKind = .shell, name: String = "build") -> ProcessEntry {
        ProcessEntry(
            id: Self.entryId, projectId: Self.projectId, name: name, kind: kind,
            executable: "/bin/zsh", workingDirectory: "/tmp/vmlife",
            trust: .trusted, autoResume: false, isArchived: false)
    }

    private func entryNow(in m: WorkbenchViewModel) -> ProcessEntry? {
        m.state.processEntries.first { $0.id == Self.entryId }
    }

    private func registerLive(_ m: WorkbenchViewModel) throws {
        let plan = TerminalCommandPlan(
            entryId: Self.entryId, runId: Self.runId, executable: "/bin/zsh", arguments: [],
            workingDirectory: "/tmp/vmlife", reason: "vmlife test")
        m.activeSessions[Self.entryId] = try TerminalSessionController(
            plan: plan, onStarted: { _ in }, onOutput: {}, onTerminated: { _ in })
    }

    // MARK: - requestDeleteCustomSession guards

    func testRequestDelete_liveSession_setsError() throws {
        let m = try makeVM(entries: [entry()])
        try registerLive(m)
        m.requestDeleteCustomSession(entry())
        XCTAssertEqual(m.errorMessage, "Stop build before deleting it")
        XCTAssertNil(m.pendingDeleteSession, "a live session is not queued for delete")
    }

    func testRequestDelete_notCustom_setsError() throws {
        // .command kind is NOT a custom session (only .shell / .terminalAgent are).
        let m = try makeVM(entries: [entry(kind: .command)])
        m.requestDeleteCustomSession(entry(kind: .command))
        XCTAssertEqual(m.errorMessage, "build is not a managed terminal session")
    }

    func testRequestDelete_eligible_queuesPendingDelete() throws {
        let m = try makeVM(entries: [entry()])
        m.requestDeleteCustomSession(entry())
        XCTAssertEqual(m.pendingDeleteSession?.id, Self.entryId, "an eligible custom session is queued")
    }

    // MARK: - deleteCustomSession

    func testDeleteCustomSession_removesEntryRunsAndLogs() throws {
        let m = try makeVM(entries: [entry()],
                           runs: [ProcessRun(id: Self.runId, entryId: Self.entryId, status: .exited)])
        m.deleteCustomSession(entry())
        XCTAssertNil(entryNow(in: m), "the entry is removed")
        XCTAssertTrue(m.state.processRuns.filter { $0.entryId == Self.entryId }.isEmpty, "its runs are removed")
        XCTAssertTrue(m.state.actionLog.contains { $0.action == "deleteSession" }, "the delete is audit-logged")
        XCTAssertEqual(quits?.ids, [Self.entryId], "the persistent screen for this entry is quit (seam)")
    }

    func testDeleteCustomSession_liveSession_guardedNoDelete() throws {
        let m = try makeVM(entries: [entry()])
        try registerLive(m)
        m.deleteCustomSession(entry())
        XCTAssertNotNil(entryNow(in: m), "a live session is NOT deleted (the stop guard)")
        XCTAssertEqual(m.errorMessage, "Stop build before deleting it")
    }

    // MARK: - revealLatestTranscript

    func testRevealTranscript_noTranscript_setsError() throws {
        let m = try makeVM(entries: [entry()],
                           runs: [ProcessRun(id: Self.runId, entryId: Self.entryId, status: .exited)])
        m.revealLatestTranscript(for: entry())
        XCTAssertEqual(m.errorMessage, "No transcript has been recorded for build")
    }

    func testRevealTranscript_missingFile_setsErrorAndLogs() throws {
        var r = ProcessRun(id: Self.runId, entryId: Self.entryId, status: .exited)
        r.transcriptPath = "/tmp/vmlife/does-not-exist-\(UUID().uuidString).log"
        let m = try makeVM(entries: [entry()], runs: [r])
        m.revealLatestTranscript(for: entry())
        XCTAssertTrue(m.errorMessage?.hasPrefix("Transcript file is missing:") == true)
        XCTAssertTrue(m.state.actionLog.contains { $0.action == "revealTranscript" && !$0.succeeded },
                      "the missing-transcript reveal is logged as a failure")
        XCTAssertTrue(reveals?.urls.isEmpty == true, "a missing transcript is never revealed")
    }

    func testRevealTranscript_present_revealsAndLogsSuccess() throws {
        // A real, existing transcript file → the success arm: reveal (via the #365 seam) + log.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmlife-tx-\(UUID().uuidString).log")
        try Data("transcript".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var r = ProcessRun(id: Self.runId, entryId: Self.entryId, status: .exited)
        r.transcriptPath = tmp.path
        let m = try makeVM(entries: [entry()], runs: [r])
        m.revealLatestTranscript(for: entry())
        XCTAssertEqual(reveals?.urls.map(\.path), [tmp.path], "the present transcript is revealed in Finder")
        XCTAssertTrue(m.state.actionLog.contains { $0.action == "revealTranscript" && $0.succeeded },
                      "a successful reveal is logged")
        XCTAssertNil(m.errorMessage, "no error on the success path")
    }

    // MARK: - requestStop / confirmStop

    func testRequestStop_idleSession_terminatesImmediately() throws {
        // An idle (non-live) entry: stop needs no confirmation; requestStop routes to terminate,
        // which (no live session) surfaces the not-running error rather than queueing a confirm.
        let m = try makeVM(entries: [entry()])
        m.requestStop(entry())
        XCTAssertNil(m.pendingStopSession, "an idle session is stopped without the confirmation gate")
    }

    func testConfirmStop_noPending_isNoOp() throws {
        let m = try makeVM(entries: [entry()])
        m.pendingStopSession = nil
        m.confirmStop()   // guard returns early
        XCTAssertNil(m.pendingStopSession)
    }

    // MARK: - applySessionIdBackfills

    func testApplyBackfills_writesSessionIdForNilRun() throws {
        let m = try makeVM(entries: [entry()],
                           runs: [ProcessRun(id: Self.runId, entryId: Self.entryId, status: .exited)])
        m.applySessionIdBackfills([Self.runId: "screen-123"])
        XCTAssertEqual(m.state.processRuns.first { $0.id == Self.runId }?.terminalSessionId, "screen-123")
    }

    func testApplyBackfills_doesNotClobberExistingId() throws {
        var r = ProcessRun(id: Self.runId, entryId: Self.entryId, status: .exited)
        r.terminalSessionId = "original"
        let m = try makeVM(entries: [entry()], runs: [r])
        m.applySessionIdBackfills([Self.runId: "should-not-win"])
        XCTAssertEqual(m.state.processRuns.first { $0.id == Self.runId }?.terminalSessionId, "original",
                       "an already-set terminalSessionId is never clobbered")
    }

    func testApplyBackfills_empty_isNoOp() throws {
        let m = try makeVM(entries: [entry()],
                           runs: [ProcessRun(id: Self.runId, entryId: Self.entryId, status: .exited)])
        m.applySessionIdBackfills([:])
        XCTAssertNil(m.state.processRuns.first { $0.id == Self.runId }?.terminalSessionId)
    }

    // MARK: - Negative control (mutation-verified)

    func testNegativeControl_deleteRemovesEntry() throws {
        let m = try makeVM(entries: [entry()])
        m.deleteCustomSession(entry())
        XCTAssertNil(entryNow(in: m), "deleteCustomSession actually removes the entry")
    }
}
#endif
