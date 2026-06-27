#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 — `SessionStatusRowView` (`:7724`) drive-to-100%.
///
/// The session-status list row (constructed inside `SessionStatusListView`) had three
/// un-driven regions: the whole-row select `Button` action, and the `detailLine`
/// fallbacks for a `.done` row with NO exit code and a `.running` row with NO pid (both
/// fall back to the working directory). Promoted private->internal for the per-file-100%
/// gate; this suite taps the row and renders the nil-metadata fixtures.
///
/// **Provenance (P2).** Real `SessionStatusRow` value fixtures + a hermetic VM whose state
/// carries the matching entry so `selectEntryAcrossGroups` resolves and sets `selectedEntryID`.
///
/// **Carves:** none.
@MainActor
final class SessionStatusRowViewDriveTests: XCTestCase {

    private static let projectId = UUID(uuidString: "55000001-0000-0000-0000-000000000001")!

    private func makeVM(entryId: UUID) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("u5-statusrow-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let entry = ProcessEntry(id: entryId, projectId: Self.projectId, name: "alpha", kind: .shell,
                                 executable: "/bin/zsh", workingDirectory: "/tmp/u5statusrow")
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: [WorkbenchProject(id: Self.projectId, name: "alpha", rootPath: "/tmp/u5statusrow")],
            processEntries: [entry],
            workspaces: [Workspace(id: UUID(uuidString: "550000AA-0000-0000-0000-0000000000AA")!,
                                   autoName: "WS", tabIds: [entryId])])
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    private func row(_ id: UUID, bucket: SessionStatusBucket, status: ProcessStatus,
                     pid: Int? = nil, exitCode: Int? = nil) -> SessionStatusRow {
        SessionStatusRow(
            id: id, name: "alpha", group: nil, owner: .human, bucket: bucket, status: status,
            attention: .active, needsHuman: false, workingDirectory: "/tmp/u5statusrow",
            pid: pid, exitCode: exitCode)
    }

    /// Tapping the row runs the select `Button { model.selectEntryAcrossGroups(row.id) }`.
    func testStatusRow_tap_selectsEntry() throws {
        let id = UUID(uuidString: "55000010-0000-0000-0000-000000000010")!
        let model = try makeVM(entryId: id)
        // The VM may auto-select the only entry on load; clear it so the tap's effect is observable.
        model.selectedEntryID = nil
        XCTAssertNil(model.selectedEntryID, "precondition: selection cleared")
        try SessionStatusRowView(row: row(id, bucket: .running, status: .running, pid: 4242), model: model)
            .inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(model.selectedEntryID, id, "tapping the row selects the entry across groups")
    }

    /// `.done` with NO exit code → the `detailLine` falls back to the working directory.
    func testStatusRow_doneWithoutExitCode_fallsBackToWorkingDirectory() throws {
        let id = UUID(uuidString: "55000011-0000-0000-0000-000000000011")!
        let model = try makeVM(entryId: id)
        let tree = try ViewSnapshotHost.snapshotText(
            of: SessionStatusRowView(row: row(id, bucket: .done, status: .exited, exitCode: nil), model: model))
        XCTAssertTrue(tree.contains("/tmp/u5statusrow"),
                      "a .done row with no exit code shows the working directory:\n\(tree)")
        XCTAssertFalse(tree.contains("exited "), "no exit-code detail when exitCode is nil:\n\(tree)")
    }

    /// `.running` with NO pid → the `detailLine` falls back to the working directory.
    func testStatusRow_runningWithoutPid_fallsBackToWorkingDirectory() throws {
        let id = UUID(uuidString: "55000012-0000-0000-0000-000000000012")!
        let model = try makeVM(entryId: id)
        let tree = try ViewSnapshotHost.snapshotText(
            of: SessionStatusRowView(row: row(id, bucket: .running, status: .running, pid: nil), model: model))
        XCTAssertTrue(tree.contains("/tmp/u5statusrow"),
                      "a .running row with no pid shows the working directory:\n\(tree)")
        XCTAssertFalse(tree.contains("pid "), "no pid detail when pid is nil:\n\(tree)")
    }
}
#endif
