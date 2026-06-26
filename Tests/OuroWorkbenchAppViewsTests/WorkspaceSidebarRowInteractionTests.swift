#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B1 — `WorkspaceSidebarRow` (`:3169`) action-closure INTERACTION drive-to-100%.
///
/// The SU3 `SidebarSurfaceStateSetTests` render the row but never tap its `rowButton` `Button`,
/// so the action `model.selectedWorkspaceID = row.id` (`L3185`) was uncovered. This suite taps the
/// row → asserting `selectedWorkspaceID`, then MUTATION-VERIFIES it.
///
/// **Provenance (P2).** `row` is a `WorkspaceRow` resolved through the REAL seam (saved state →
/// fresh VM `load()` → `workspaceSidebarModel.rows`), re-read off the model. AN-001 hermetic.
///
/// **Determinism (P3).** Fixed ids; FIXED `/tmp/u5b1wsr` working dir; no clock; `!contains("/Users/")`.
@MainActor
final class WorkspaceSidebarRowInteractionTests: XCTestCase {

    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000FB")!
    private static let wsA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000E1")!
    private static let wsB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-0000000000E2")!
    private static let tab1 = UUID(uuidString: "11111111-0000-0000-0000-0000000000E1")!
    private static let tab2 = UUID(uuidString: "22222222-0000-0000-0000-0000000000E2")!

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b1-wsr-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        func tab(_ id: UUID, _ name: String) -> ProcessEntry {
            ProcessEntry(id: id, projectId: Self.projectId, name: name, kind: .shell,
                         executable: "/bin/zsh", workingDirectory: "/tmp/u5b1wsr")
        }
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            processEntries: [tab(Self.tab1, "alpha"), tab(Self.tab2, "bravo")],
            workspaces: [
                Workspace(id: Self.wsA, autoName: "Alpha", tabIds: [Self.tab1]),
                Workspace(id: Self.wsB, autoName: "Bravo", tabIds: [Self.tab2])
            ])
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    /// The row for the Bravo workspace (NOT the active/selected one, so tapping it actually
    /// CHANGES selectedWorkspaceID to an observable new value).
    private func bravoRowAndModel() throws -> (WorkspaceSidebarRow, WorkbenchViewModel) {
        let model = try makeVM()
        let row = try XCTUnwrap(model.workspaceSidebarModel.rows.first(where: { $0.id == Self.wsB }),
                                "the Bravo workspace resolved to a row")
        return (WorkspaceSidebarRow(row: row, model: model), model)
    }

    // MARK: - rowButton action (select the workspace)

    func testTap_rowButton_selectsWorkspace() throws {
        let (view, model) = try bravoRowAndModel()
        XCTAssertNotEqual(model.selectedWorkspaceID, Self.wsB, "provenance: Bravo not yet selected")
        try view.inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(model.selectedWorkspaceID, Self.wsB, "tapping the row selects its workspace")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The select action is load-bearing: tapping the row sets selectedWorkspaceID to THIS row.
    /// (Mutation-verify: replacing `model.selectedWorkspaceID = row.id` with a no-op → RED.)
    func testNegativeControl_rowTapSetsSelection() throws {
        let (view, model) = try bravoRowAndModel()
        let before = model.selectedWorkspaceID
        try view.inspect().find(ViewType.Button.self).tap()
        XCTAssertNotEqual(before, model.selectedWorkspaceID, "the row tap must change the selected workspace")
        XCTAssertEqual(model.selectedWorkspaceID, Self.wsB, "and the new value is this row's id")
    }
}
#endif
