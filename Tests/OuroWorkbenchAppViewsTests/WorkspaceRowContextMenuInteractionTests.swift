#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B1 — `WorkspaceRowContextMenu` (`:3234`) action-closure INTERACTION drive-to-100%.
///
/// The C1 `WorkspaceRowContextMenuStandaloneTests` snapshot the Pin/Rename/Remove-override
/// LABELS but never EXECUTE the three `Button` actions (`toggleWorkspacePin`, `beginRename`,
/// `removeCustomWorkspaceName`), so all three action-closure regions were uncovered. This suite
/// FINDS each button and `.tap()`s it → asserting its `@Published`/`state` side-effect, then
/// MUTATION-VERIFIES the pin action.
///
/// **Provenance (P2).** `row` is a `WorkspaceSidebarPresentation.WorkspaceRow` resolved through
/// the REAL seam: `WorkbenchStore(paths:).save(state)` → a fresh `WorkbenchViewModel` whose
/// `load()` derives `model.workspaceSidebarModel.rows`. The row is re-read off the model, never
/// hand-assembled. AN-001 dual-injection keeps the inventory scan hermetic.
///
/// **Determinism (P3).** Fixed ids; no clock/path/UUID in any asserted artifact; `!contains("/Users/")`.
@MainActor
final class WorkspaceRowContextMenuInteractionTests: XCTestCase {

    private static let wsId = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private static let tabId = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b1-wsmenu-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private func tab() -> ProcessEntry {
        ProcessEntry(id: Self.tabId, projectId: Self.projectId, name: "build", kind: .shell,
                     executable: "/bin/zsh", workingDirectory: "/tmp/u5b1")
    }

    /// Build a VM whose single workspace resolves to a row with the given pin/override flags,
    /// then read the resolved row off the model + return both (so taps observe the model).
    private func menuAndModel(isPinned: Bool = false, nameOverride: String? = nil)
        throws -> (WorkspaceRowContextMenu, WorkbenchViewModel) {
        let workspace = Workspace(id: Self.wsId, autoName: "Frontend", nameOverride: nameOverride,
                                  isPinned: isPinned, tabIds: [Self.tabId])
        let state = WorkspaceState(boss: BossAgentSelection(agentName: "boss"),
                                   processEntries: [tab()], workspaces: [workspace])
        let model = try makeVM(state: state)
        let row = try XCTUnwrap(model.workspaceSidebarModel.rows.first, "the workspace resolved to a row")
        return (WorkspaceRowContextMenu(row: row, model: model), model)
    }

    // MARK: - Pin / Unpin

    func testTap_pin_unpinnedWorkspace_pinsIt() throws {
        let (view, model) = try menuAndModel(isPinned: false)
        XCTAssertFalse(model.state.workspaces.first?.isPinned ?? true, "provenance: unpinned")
        try view.inspect().find(button: "Pin Workspace").tap()
        XCTAssertTrue(model.state.workspaces.first?.isPinned ?? false, "Pin Workspace pins it")
    }

    func testTap_unpin_pinnedWorkspace_unpinsIt() throws {
        let (view, model) = try menuAndModel(isPinned: true)
        XCTAssertTrue(model.state.workspaces.first?.isPinned ?? false, "provenance: pinned")
        try view.inspect().find(button: "Unpin Workspace").tap()
        XCTAssertFalse(model.state.workspaces.first?.isPinned ?? true, "Unpin Workspace unpins it")
    }

    // MARK: - Rename Workspace…

    func testTap_rename_beginsInlineRename() throws {
        let (view, model) = try menuAndModel()
        XCTAssertFalse(model.inlineRename.isEditing(.workspace(Self.wsId)), "provenance: not renaming")
        try view.inspect().find(button: "Rename Workspace…  ⇧⌘R").tap()
        XCTAssertTrue(model.inlineRename.isEditing(.workspace(Self.wsId)),
                      "Rename Workspace… begins the inline rename for this workspace")
        XCTAssertEqual(model.inlineRename.draft, "Frontend", "the draft is prefilled with effectiveName")
    }

    // MARK: - Remove Custom Workspace Name (the nameOverride != nil arm)

    func testTap_removeCustomName_clearsOverride() throws {
        let (view, model) = try menuAndModel(nameOverride: "Custom Name")
        XCTAssertEqual(model.state.workspaces.first?.nameOverride, "Custom Name", "provenance: custom name set")
        try view.inspect().find(button: "Remove Custom Workspace Name").tap()
        XCTAssertNil(model.state.workspaces.first?.nameOverride, "Remove Custom Workspace Name clears the override")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The pin action is load-bearing: tapping it flips the workspace's pin state. (Mutation-verify:
    /// replacing `model.toggleWorkspacePin(row.id)` with a no-op leaves isPinned false → RED.)
    func testNegativeControl_pinActionTogglesWorkspacePin() throws {
        let (view, model) = try menuAndModel(isPinned: false)
        let before = model.state.workspaces.first?.isPinned ?? false
        try view.inspect().find(button: "Pin Workspace").tap()
        XCTAssertNotEqual(before, model.state.workspaces.first?.isPinned ?? false,
                          "the pin action must change the workspace pin state")
    }
}
#endif
