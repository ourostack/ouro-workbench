#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B5 — `CustomSessionManagementBar` (`:9356`) close-out. C9 drove the Archive/Restore
/// RENDER flip + the Move menu render, but carved all the button ACTION closures and the
/// `isRunning`-true `.help(…)` ternary arms. The 10 uncovered:
///   - `L9362` Edit ACTION, `L9370` Duplicate ACTION, `L9378` Move-project ACTION,
///     `L9390` Restore ACTION, `L9396` Archive ACTION, `L9405` Delete ACTION;
///   - `L9368`/`L9387`/`L9402`/`L9411` — the `isRunning ? "Stop … before …" : …` help ternary
///     TRUE arms (only evaluated when a live session backs the entry).
///
/// DRIVEN:
///   - the six button ACTIONS via `.tap()` (one fresh model per tap → independent assertion of
///     each `@Published` side-effect: `editingSession`, appended `processEntries`, changed
///     `projectId`, restored/archived `isArchived`, `pendingDeleteSession`);
///   - the four `isRunning`-true help-ternary arms by CONSTRUCTING the bar with a live session
///     injected (no-PTY `TerminalSessionController` in `activeSessions`) — the body's ternaries
///     evaluate during ViewInspector traversal (the `.help` tooltip node is dropped by the host,
///     but the ternary still EXECUTES → the region is colored). Non-vacuity: `isRunning == true`.
@MainActor
final class CustomSessionManagementBarDriveTests: XCTestCase {

    private static let entryId = UUID(uuidString: "B5C5811B-0000-0000-0000-0000000000E1")!
    private static let projectId = UUID(uuidString: "B5C5811B-0000-0000-0000-0000000000A1")!
    private static let altProjectId = UUID(uuidString: "B5C5811B-0000-0000-0000-0000000000A2")!
    private static let wsId = UUID(uuidString: "B5C5811B-0000-0000-0000-0000000000B1")!

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b5mgmt-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    private func entry(isArchived: Bool = false) -> ProcessEntry {
        ProcessEntry(
            id: Self.entryId, projectId: Self.projectId, name: "build",
            kind: .shell, executable: "/bin/zsh", workingDirectory: "/tmp/u5",
            isArchived: isArchived)
    }

    /// Two projects so the Move menu is enabled + the ForEach renders an enabled target.
    private func state(entry: ProcessEntry) -> WorkspaceState {
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: [
                WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp/u5"),
                WorkbenchProject(id: Self.altProjectId, name: "Other", rootPath: "/tmp/u5-other"),
            ],
            processEntries: [entry],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS",
                                   tabIds: entry.isArchived ? [] : [Self.entryId])])
    }

    private func loaded(_ m: WorkbenchViewModel, fallback: ProcessEntry) -> ProcessEntry {
        m.state.processEntries.first ?? fallback
    }

    private func bar(_ m: WorkbenchViewModel, entry: ProcessEntry) -> CustomSessionManagementBar {
        CustomSessionManagementBar(entry: entry, model: m)
    }

    private func session(for entry: ProcessEntry) throws -> TerminalSessionController {
        let plan = TerminalCommandPlan(entryId: entry.id, executable: "/bin/zsh", arguments: [],
                                       workingDirectory: "/tmp/u5", reason: "test")
        return try TerminalSessionController(plan: plan, onStarted: { _ in }, onOutput: {}, onTerminated: { _ in })
    }

    // MARK: - L9362 — Edit ACTION

    func testBar_editTap_setsEditingSession() throws {
        let e = entry(); let m = try makeVM(state: state(entry: e)); let le = loaded(m, fallback: e)
        XCTAssertNil(m.editingSession, "no editing session before tap")
        try bar(m, entry: le).inspect().find(button: "Edit").tap()
        XCTAssertEqual(m.editingSession?.id, le.id, "Edit tap → beginEditingSession sets editingSession")
    }

    // MARK: - L9370 — Duplicate ACTION

    func testBar_duplicateTap_appendsEntry() throws {
        let e = entry(); let m = try makeVM(state: state(entry: e)); let le = loaded(m, fallback: e)
        XCTAssertEqual(m.state.processEntries.count, 1, "one entry before tap")
        try bar(m, entry: le).inspect().find(button: "Duplicate").tap()
        XCTAssertEqual(m.state.processEntries.count, 2, "Duplicate tap → a second entry is appended")
    }

    // MARK: - L9378 — Move-project ACTION

    func testBar_moveTap_changesProjectId() throws {
        let e = entry(); let m = try makeVM(state: state(entry: e)); let le = loaded(m, fallback: e)
        XCTAssertEqual(m.state.processEntries.first?.projectId, Self.projectId, "Home before move")
        // The Move menu's enabled target is the "Other" project (the current one is disabled).
        try bar(m, entry: le).inspect().find(button: "Other").tap()
        XCTAssertEqual(m.state.processEntries.first?.projectId, Self.altProjectId,
                       "Move tap → moveSession changes the entry's projectId")
    }

    // MARK: - L9396 — Archive ACTION

    func testBar_archiveTap_archivesEntry() throws {
        let e = entry(); let m = try makeVM(state: state(entry: e)); let le = loaded(m, fallback: e)
        XCTAssertFalse(m.state.processEntries.first?.isArchived ?? true, "not archived before tap")
        try bar(m, entry: le).inspect().find(button: "Archive").tap()
        XCTAssertTrue(m.state.processEntries.first?.isArchived ?? false, "Archive tap → entry archived")
    }

    // MARK: - L9390 — Restore ACTION (archived arm)

    func testBar_restoreTap_restoresEntry() throws {
        let e = entry(isArchived: true); let m = try makeVM(state: state(entry: e)); let le = loaded(m, fallback: e)
        XCTAssertTrue(le.isArchived, "archived before tap")
        try bar(m, entry: le).inspect().find(button: "Restore").tap()
        XCTAssertFalse(m.state.processEntries.first?.isArchived ?? true, "Restore tap → un-archived")
    }

    // MARK: - L9405 — Delete ACTION

    func testBar_deleteTap_setsPendingDelete() throws {
        let e = entry(); let m = try makeVM(state: state(entry: e)); let le = loaded(m, fallback: e)
        XCTAssertNil(m.pendingDeleteSession, "no pending delete before tap")
        try bar(m, entry: le).inspect().find(button: "Delete").tap()
        XCTAssertEqual(m.pendingDeleteSession?.id, le.id, "Delete tap → requestDeleteCustomSession sets pendingDeleteSession")
    }

    // MARK: - L9368/9387/9402/9411 — the isRunning-true help-ternary arms

    func testBar_runningEntry_evaluatesIsRunningTrueHelpArms() throws {
        let e = entry()
        let m = try makeVM(state: state(entry: e))
        let le = loaded(m, fallback: e)
        m.activeSessions[le.id] = try session(for: le)
        XCTAssertNotNil(m.activeSession(for: le), "provenance: live session → isRunning == true")
        // Constructing + traversing the bar evaluates the `isRunning ? … : …` help ternaries
        // (the true arms). The tree still renders the Edit/Duplicate/Move/Archive/Delete labels.
        let tree = try ViewSnapshotHost.snapshotText(of: bar(m, entry: le))
        XCTAssertTrue(tree.contains(#"text="Edit""#), "the bar renders while running:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Archive""#), "Archive label (running → disabled):\n\(tree)")
        try assertViewSnapshot(of: bar(m, entry: le), named: "CustomSessionManagementBar.running")
    }

    // MARK: - Determinism (P3)

    func testBar_deterministic_noLeak() throws {
        func make() throws -> String {
            let e = entry(); let m = try makeVM(state: state(entry: e))
            return try ViewSnapshotHost.snapshotText(of: bar(m, entry: loaded(m, fallback: e)))
        }
        let a = try make(); let b = try make()
        XCTAssertEqual(a, b, "must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no /Users/ leak:\n\(a)")
        XCTAssertFalse(a.contains("/var/folders/"), "no temp-dir leak:\n\(a)")
    }
}
#endif
