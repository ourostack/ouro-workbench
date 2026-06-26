#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B5 — `RunningSessionHeaderControls` (`:9644`) — the top B5 offender (35 uncovered).
/// The campaign never drove this view: it needs the `Menu{}` descended (it IS, per the
/// B4 note) PLUS fixtures that produce each `SessionActionMenu.Action` (running vs non-running,
/// custom) and each `WorkbenchSurfacePolicy.SessionAction` primary button (stop/launch/recover).
///
/// Two seams drive the whole decl:
///   - `SessionActionMenu.layout(isRunning:isCustomSession:)` decides which `menuButton(for:)`
///     switch arms are BUILT (rendered → the case region is colored). A non-running custom
///     session yields askBoss + copy/openDir/edit/duplicate/move/archive/delete; a RUNNING
///     custom session ALSO yields controlC/escape/eof/redraw/focus/restart.
///   - `WorkbenchSurfacePolicy.sessionControls(...)` decides the `primaryButton(for:)` arm:
///     running → `.stop`; recoverable → `.recover`; else → `.launch`.
///
/// DRIVEN: render every menu arm across a running + a non-running custom fixture (the switch
/// cases + Labels), each primary arm across stop/launch/recover fixtures, then INVOKE a
/// representative set of the menu/primary ACTION closures via `.tap()` asserting the
/// `@Published`/`actionLog` side-effect (spawn-risky launch/recover/restart use the
/// EMPTY-executable planner-throws seam → `errorMessage`, no process).
@MainActor
final class RunningSessionHeaderControlsDriveTests: XCTestCase {

    private static let entryId = UUID(uuidString: "B5811D60-0000-0000-0000-0000000000E1")!
    private static let projectId = UUID(uuidString: "B5811D60-0000-0000-0000-0000000000A1")!
    private static let altProjectId = UUID(uuidString: "B5811D60-0000-0000-0000-0000000000A2")!
    private static let wsId = UUID(uuidString: "B5811D60-0000-0000-0000-0000000000B1")!
    private static let runEpoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b5running-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    private func entry(
        executable: String = "/bin/zsh", isArchived: Bool = false, autoResume: Bool = false,
        attention: AttentionState = .idle
    ) -> ProcessEntry {
        ProcessEntry(
            id: Self.entryId, projectId: Self.projectId, name: "build",
            kind: .shell, executable: executable, workingDirectory: "/tmp/u5",
            trust: .trusted, autoResume: autoResume, isArchived: isArchived, attention: attention)
    }

    private func run(_ status: ProcessStatus) -> ProcessRun {
        ProcessRun(id: UUID(uuidString: "B5811D60-0000-0000-0000-0000000000F1")!,
                   entryId: Self.entryId, status: status, startedAt: Self.runEpoch)
    }

    private func state(entry: ProcessEntry, runs: [ProcessRun] = [], twoProjects: Bool = true) -> WorkspaceState {
        var projects = [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp/u5")]
        if twoProjects { projects.append(WorkbenchProject(id: Self.altProjectId, name: "Other", rootPath: "/tmp/u5-other")) }
        return WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: projects,
            processEntries: [entry],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: entry.isArchived ? [] : [Self.entryId])],
            processRuns: runs)
    }

    private func loaded(_ m: WorkbenchViewModel, fallback: ProcessEntry) -> ProcessEntry {
        m.state.processEntries.first ?? fallback
    }

    private func session(for entry: ProcessEntry) throws -> TerminalSessionController {
        let plan = TerminalCommandPlan(entryId: entry.id, executable: "/bin/zsh", arguments: [],
                                       workingDirectory: "/tmp/u5", reason: "test")
        return try TerminalSessionController(plan: plan, onStarted: { _ in }, onOutput: {}, onTerminated: { _ in })
    }

    private func controls(_ m: WorkbenchViewModel, entry e: ProcessEntry) -> RunningSessionHeaderControls {
        RunningSessionHeaderControls(entry: e, model: m)
    }

    /// A running custom session (live no-PTY controller) → every menu arm + the .stop primary.
    private func runningModel(executable: String = "/bin/zsh",
                             attention: AttentionState = .idle) throws -> (WorkbenchViewModel, ProcessEntry) {
        let e = entry(executable: executable, attention: attention)
        let m = try makeVM(state: state(entry: e))
        let le = loaded(m, fallback: e)
        m.activeSessions[le.id] = try session(for: le)
        return (m, le)
    }

    // MARK: - Render the full menu (every switch arm) — running + non-running custom

    func testControls_runningCustom_buildsEverySendAndWindowArm() throws {
        let (m, le) = try runningModel()
        XCTAssertTrue(m.isCustomSession(le)); XCTAssertNotNil(m.activeSession(for: le))
        let tree = try ViewSnapshotHost.snapshotText(of: controls(m, entry: le))
        // The Send-section + Window-section + This-Session arms all render their Labels.
        for label in ["Ctrl-C", "Esc", "EOF", "Redraw", "Focus", "Restart",
                      "Copy Launch Command", "Open Working Directory", "Edit Session…",
                      "Duplicate Session", "Move to Workspace", "Archive Session",
                      "Delete Session…", "Ask Boss About This Session", "Stop"] {
            XCTAssertTrue(tree.contains(#"text="\#(label)""#), "the running menu builds \(label):\n\(tree)")
        }
        try assertViewSnapshot(of: controls(m, entry: le), named: "RunningSessionHeaderControls.running")
    }

    func testControls_nonRunningCustom_buildsThisSessionArms() throws {
        let e = entry()
        let m = try makeVM(state: state(entry: e))
        let le = loaded(m, fallback: e)
        XCTAssertNil(m.activeSession(for: le))
        // NOTE: `WorkbenchSurfacePolicy.sessionControls` reads `isRecoverable:
        // model.recoveryPlan(for:) != nil`, and `summary.recoveryPlans` emits a plan for EVERY
        // in-state entry (including a `.noAction` no-op), so an in-state non-running non-archived
        // entry is ALWAYS `isRecoverable == true` → the primary is `.recover`, never `.launch`.
        // (The `.launch` primary arm is therefore unreachable for this view — recorded carve.)
        let tree = try ViewSnapshotHost.snapshotText(of: controls(m, entry: le))
        for label in ["Ask Boss About This Session", "Copy Launch Command", "Open Working Directory",
                      "Edit Session…", "Duplicate Session", "Move to Workspace", "Archive Session",
                      "Delete Session…", "Recover"] {
            XCTAssertTrue(tree.contains(#"text="\#(label)""#), "the non-running menu builds \(label):\n\(tree)")
        }
        XCTAssertFalse(tree.contains(#"text="Restart""#), "non-running: no Restart:\n\(tree)")
        try assertViewSnapshot(of: controls(m, entry: le), named: "RunningSessionHeaderControls.nonRunning")
    }

    // MARK: - The .recover primary arm

    func testControls_recoverable_buildsRecoverPrimary() throws {
        let e = entry(autoResume: true)
        let m = try makeVM(state: state(entry: e, runs: [run(.needsRecovery)]))
        let le = loaded(m, fallback: e)
        XCTAssertNotNil(m.recoveryPlan(for: le), "provenance: recoverable → the .recover primary")
        let tree = try ViewSnapshotHost.snapshotText(of: controls(m, entry: le))
        XCTAssertTrue(tree.contains(#"text="Recover""#), "the Recover primary button:\n\(tree)")
    }

    // MARK: - INVOKE the send-key + window + this-session menu ACTIONS (running fixture)

    func testControls_runningMenuTaps_recordActionLog() throws {
        // Each send-key tap records an action-log entry (the model methods call recordActionLog).
        for (label, action) in [("Ctrl-C", "sendControlC"), ("Esc", "sendEscape"),
                                 ("EOF", "sendEOF"), ("Redraw", "redrawTerminal")] {
            let (m, le) = try runningModel()
            let before = m.state.actionLog.count
            try controls(m, entry: le).inspect().find(button: label).tap()
            XCTAssertEqual(m.state.actionLog.count, before + 1, "\(label) tap → \(action) records an action log")
            XCTAssertEqual(m.state.actionLog.first?.action, action, "the \(label) tap action")
        }
    }

    func testControls_askBossTap_setsBossQuestion() async throws {
        // The askBoss arm is `Button { Task { await model.runBossQuestion(about: entry) } }`.
        // Tapping creates the Task; `runBossQuestion(about:)` SYNCHRONOUSLY sets `bossQuestion`
        // as its first statement (before any await), so after the Task body starts we can assert
        // it — coloring the Button action + the `Task {` closure. (The fixture is hermetic — no
        // real boss daemon — so the trailing `runBossCheckIn` await fails fast.)
        let (m, le) = try runningModel()
        XCTAssertTrue(m.bossQuestion.isEmpty, "no boss question before tap")
        try controls(m, entry: le).inspect().find(button: "Ask Boss About This Session").tap()
        // Let the Task body run far enough to set bossQuestion (its first, pre-await statement).
        for _ in 0..<50 where m.bossQuestion.isEmpty { await Task.yield() }
        XCTAssertTrue(m.bossQuestion.contains("build"),
                      "askBoss tap → runBossQuestion sets bossQuestion: \(m.bossQuestion)")
    }

    func testControls_focusTap_setsTerminalFocus() throws {
        let (m, le) = try runningModel()
        try controls(m, entry: le).inspect().find(button: "Focus").tap()
        XCTAssertEqual(m.terminalFocusEntryID, le.id, "Focus tap → focusTerminal sets terminalFocusEntryID")
    }

    func testControls_copyLaunchTap_recordsActionLog() throws {
        let (m, le) = try runningModel()
        let before = m.state.actionLog.count
        try controls(m, entry: le).inspect().find(button: "Copy Launch Command").tap()
        XCTAssertEqual(m.state.actionLog.count, before + 1, "Copy tap → copyLaunchCommand records")
        XCTAssertEqual(m.state.actionLog.first?.action, "copyLaunchCommand")
    }

    func testControls_openWorkingDirectoryTap_recordsActionLog() throws {
        // A non-existent working dir → openWorkingDirectory sets errorMessage + records a failed log.
        let (m, le) = try runningModel()
        try controls(m, entry: le).inspect().find(button: "Open Working Directory").tap()
        XCTAssertEqual(m.state.actionLog.first?.action, "openWorkingDirectory", "Open Dir tap records")
    }

    // MARK: - The lifecycle menu ACTIONS (non-running custom) + the spawn-free launch/recover/restart

    func testControls_editDuplicateMoveArchiveDeleteTaps() throws {
        // Edit
        do { let e = entry(); let m = try makeVM(state: state(entry: e)); let le = loaded(m, fallback: e)
             try controls(m, entry: le).inspect().find(button: "Edit Session…").tap()
             XCTAssertEqual(m.editingSession?.id, le.id, "Edit Session → editingSession") }
        // Duplicate
        do { let e = entry(); let m = try makeVM(state: state(entry: e)); let le = loaded(m, fallback: e)
             try controls(m, entry: le).inspect().find(button: "Duplicate Session").tap()
             XCTAssertEqual(m.state.processEntries.count, 2, "Duplicate Session → +1 entry") }
        // Move (the "Other" target)
        do { let e = entry(); let m = try makeVM(state: state(entry: e)); let le = loaded(m, fallback: e)
             try controls(m, entry: le).inspect().find(button: "Other").tap()
             XCTAssertEqual(m.state.processEntries.first?.projectId, Self.altProjectId, "Move → projectId") }
        // Archive
        do { let e = entry(); let m = try makeVM(state: state(entry: e)); let le = loaded(m, fallback: e)
             try controls(m, entry: le).inspect().find(button: "Archive Session").tap()
             XCTAssertTrue(m.state.processEntries.first?.isArchived ?? false, "Archive Session → archived") }
        // Delete
        do { let e = entry(); let m = try makeVM(state: state(entry: e)); let le = loaded(m, fallback: e)
             try controls(m, entry: le).inspect().find(button: "Delete Session…").tap()
             XCTAssertEqual(m.pendingDeleteSession?.id, le.id, "Delete Session → pendingDeleteSession") }
    }

    func testControls_restartTap_setsErrorOnEmptyExecutable() throws {
        // Restart is a running-menu action → launch; EMPTY executable → planner throws → errorMessage.
        let (m, le) = try runningModel(executable: "")
        try controls(m, entry: le).inspect().find(button: "Restart").tap()
        XCTAssertNotNil(m.errorMessage, "Restart tap on empty executable → errorMessage (no spawn)")
    }

    func testControls_recoverPrimaryTap_setsErrorOnEmptyExecutable() throws {
        let e = entry(executable: "", autoResume: true)
        let m = try makeVM(state: state(entry: e, runs: [run(.needsRecovery)]))
        let le = loaded(m, fallback: e)
        try controls(m, entry: le).inspect().find(button: "Recover").tap()
        XCTAssertNotNil(m.errorMessage, "Recover primary tap on empty executable → errorMessage")
    }

    func testControls_stopPrimaryTap_requestsStop() throws {
        // A running session with non-idle attention → the .stop primary → requestStop →
        // pendingStopSession (the confirmation gate; NOT an immediate terminate).
        let (m, le) = try runningModel(attention: .waitingOnHuman)
        XCTAssertNil(m.pendingStopSession, "no pending stop before tap")
        try controls(m, entry: le).inspect().find(button: "Stop").tap()
        XCTAssertEqual(m.pendingStopSession?.id, le.id,
                       "Stop tap → requestStop sets pendingStopSession (live agent → confirmation)")
    }

    // MARK: - Determinism (P3)

    func testControls_deterministic_noLeak() throws {
        func make() throws -> String {
            let (m, le) = try runningModel()
            return try ViewSnapshotHost.snapshotText(of: controls(m, entry: le))
        }
        let a = try make(); let b = try make()
        XCTAssertEqual(a, b, "must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no /Users/ leak:\n\(a)")
        XCTAssertFalse(a.contains("/var/folders/"), "no temp-dir leak:\n\(a)")
    }
}
#endif
