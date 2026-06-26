#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B1 — `WorkspaceTabContextMenu` (`:3446`) STANDALONE drive-to-100%.
///
/// This single-button context menu had NO dedicated test, so its whole body (the "Rename Tab…"
/// `Button` action `beginRename(.tab(tab.id), …)` + its `Label`) was uncovered. ViewInspector does
/// not descend a parent's `.contextMenu { }`, so the menu is the unit-under-test STANDALONE. This
/// suite renders it (covers the Label) and taps the button (covers the action), asserting the
/// inline-rename begins, then MUTATION-VERIFIES the action.
///
/// **Provenance (P2).** `tab` is a `ResolvedTab` resolved through the REAL seam
/// (`model.workspaceTabRows(for: activeWorkspaceRow).map(\.resolved)`), never hand-assembled.
/// AN-001 hermetic.
///
/// **Determinism (P3).** Fixed ids; FIXED `/tmp/u5b1tcm` working dir; no clock; `!contains("/Users/")`.
@MainActor
final class WorkspaceTabContextMenuInteractionTests: XCTestCase {

    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000FD")!
    private static let wsA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000C1")!
    private static let tabId = UUID(uuidString: "11111111-0000-0000-0000-0000000000C1")!

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b1-tcm-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private func menuAndModel() throws -> (WorkspaceTabContextMenu, WorkbenchViewModel) {
        let entry = ProcessEntry(id: Self.tabId, projectId: Self.projectId, name: "build", kind: .shell,
                                 executable: "/bin/zsh", workingDirectory: "/tmp/u5b1tcm")
        let state = WorkspaceState(boss: BossAgentSelection(agentName: "boss"),
                                   processEntries: [entry],
                                   workspaces: [Workspace(id: Self.wsA, autoName: "Frontend", tabIds: [Self.tabId])])
        let model = try makeVM(state: state)
        let active = try XCTUnwrap(model.activeWorkspaceRow, "an active workspace")
        let resolved = try XCTUnwrap(model.workspaceTabRows(for: active).map(\.resolved).first, "a resolved tab")
        return (WorkspaceTabContextMenu(tab: resolved, model: model), model)
    }

    // MARK: - Rename Tab… (the only Button — renders its Label + executes beginRename)

    func testRendersRenameTabLabel() throws {
        let (view, _) = try menuAndModel()
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("Rename Tab"), "the Rename Tab label renders:\n\(tree)")
        XCTAssertTrue(tree.contains("pencil"), "the pencil glyph renders:\n\(tree)")
    }

    func testTap_renameTab_beginsInlineRenameForTab() throws {
        let (view, model) = try menuAndModel()
        XCTAssertFalse(model.inlineRename.isEditing(.tab(Self.tabId)), "provenance: not renaming")
        try view.inspect().find(button: "Rename Tab…  ⌘R").tap()
        XCTAssertTrue(model.inlineRename.isEditing(.tab(Self.tabId)),
                      "Rename Tab… begins the inline rename for THIS tab")
        XCTAssertEqual(model.inlineRename.draft, "build", "the draft is prefilled with effectiveTabName")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The rename action is load-bearing: tapping it puts THIS tab into rename mode. (Mutation-verify:
    /// making `beginRename` a no-op leaves isEditing(.tab) false → RED.)
    func testNegativeControl_renameActionBeginsRename() throws {
        let (view, model) = try menuAndModel()
        let before = model.inlineRename.isEditing(.tab(Self.tabId))
        try view.inspect().find(button: "Rename Tab…  ⌘R").tap()
        XCTAssertNotEqual(before, model.inlineRename.isEditing(.tab(Self.tabId)),
                          "the rename action must enter rename mode for this tab")
    }

    // MARK: - Determinism (P3)

    func testMenu_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try menuAndModel().0)
        let b = try ViewSnapshotHost.snapshotText(of: try menuAndModel().0)
        XCTAssertEqual(a, b, "the tab context menu must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
    }
}
#endif
