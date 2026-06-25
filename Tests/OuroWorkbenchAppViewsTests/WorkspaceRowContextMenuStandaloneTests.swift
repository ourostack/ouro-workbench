#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C1 — `WorkspaceRowContextMenu` (`:3194`), the sidebar workspace-row right-click menu.
/// ViewInspector's synchronous `findAll` does NOT descend a parent's `.contextMenu { }`
/// (the C0 standalone-menu recipe, playbook #5), so we snapshot it STANDALONE via its own
/// initializer. Its data-driven captured tree:
///   - the pin Label flips on `row.isPinned` ("Pin Workspace"/`pin` ↔ "Unpin Workspace"/`pin.slash`).
///   - the Rename Label is always present.
///   - `if row.nameOverride != nil` → a "Remove Custom Workspace Name" Label appears (the
///     revert affordance, only for a workspace with a custom name).
///
/// **Provenance (P2).** The menu's `row` is a `WorkspaceSidebarPresentation.WorkspaceRow`
/// resolved through the REAL seam: `WorkbenchStore(paths:).save(state)` → a fresh
/// `WorkbenchViewModel` whose `load()` derives `model.workspaceSidebarModel.rows` via the
/// pure `WorkspaceSidebarPresentation.resolve` producer (the SidebarSurfaceStateSet seam).
/// We read the resolved row back off the model — never hand-assembled. AN-001: the temp
/// `agentBundlesURL` dual-injection keeps the inventory scan hermetic.
///
/// **Determinism (P3).** Fixed workspace ids + fixed names; no clock/path/UUID in the tree;
/// `.help` dropped (AN-004); byte-identical twice; `!contains("/Users/")`.
///
/// **Enumerated state-set (the menu's data-driven branches):**
///   - `unpinnedNoOverride` — not pinned, no custom name → "Pin Workspace" + "Rename"; NO
///                            "Remove Custom Workspace Name".
///   - `pinned`             — pinned → "Unpin Workspace" / `pin.slash` (the pin flip).
///   - `customOverride`     — a `nameOverride` set → the "Remove Custom Workspace Name" arm.
@MainActor
final class WorkspaceRowContextMenuStandaloneTests: XCTestCase {

    private static let wsId = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private static let tabId = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c1wsmenu-\(UUID().uuidString)", isDirectory: true)
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
        ProcessEntry(
            id: Self.tabId, projectId: Self.projectId, name: "build", kind: .shell,
            executable: "/bin/zsh", workingDirectory: "/tmp/u4"
        )
    }

    /// Build a VM whose single workspace resolves to a row with the given pin/override flags,
    /// then read the resolved row off the model (provenance through the real seam).
    private func menu(isPinned: Bool = false, nameOverride: String? = nil) throws -> WorkspaceRowContextMenu {
        let workspace = Workspace(
            id: Self.wsId, autoName: "Frontend", nameOverride: nameOverride,
            isPinned: isPinned, tabIds: [Self.tabId]
        )
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            processEntries: [tab()], workspaces: [workspace]
        )
        let model = try makeVM(state: state)
        let row = try XCTUnwrap(model.workspaceSidebarModel.rows.first, "the workspace resolved to a row")
        return WorkspaceRowContextMenu(row: row, model: model)
    }

    // MARK: - Enumerated state-set

    func testMenu_unpinnedNoOverride() throws {
        let view = try menu(isPinned: false, nameOverride: nil)
        XCTAssertFalse(view.row.isPinned, "provenance: unpinned")
        XCTAssertNil(view.row.nameOverride, "provenance: no custom name")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("Pin Workspace"), "unpinned: the Pin label:\n\(tree)")
        XCTAssertTrue(tree.contains("Rename Workspace"), "the Rename label is always present:\n\(tree)")
        XCTAssertFalse(tree.contains("Remove Custom Workspace Name"), "no override: no revert arm:\n\(tree)")
        try assertViewSnapshot(of: view, named: "WorkspaceRowContextMenu.unpinnedNoOverride")
    }

    func testMenu_pinned() throws {
        let view = try menu(isPinned: true, nameOverride: nil)
        XCTAssertTrue(view.row.isPinned, "provenance: pinned")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("Unpin Workspace"), "pinned: the Unpin label:\n\(tree)")
        XCTAssertTrue(tree.contains("pin.slash"), "pinned: the unpin glyph:\n\(tree)")
        try assertViewSnapshot(of: view, named: "WorkspaceRowContextMenu.pinned")
    }

    func testMenu_customOverride() throws {
        let view = try menu(isPinned: false, nameOverride: "Custom Name")
        XCTAssertEqual(view.row.nameOverride, "Custom Name", "provenance: override present")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("Remove Custom Workspace Name"), "override: the revert arm renders:\n\(tree)")
        try assertViewSnapshot(of: view, named: "WorkspaceRowContextMenu.customOverride")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The pin flag flips Pin↔Unpin; the `nameOverride != nil` gate adds the revert arm.
    func testMenu_negativeControl_pinAndOverrideFlipTree() throws {
        let unpinned = try ViewSnapshotHost.snapshotText(of: try menu(isPinned: false))
        let pinned = try ViewSnapshotHost.snapshotText(of: try menu(isPinned: true))
        let overridden = try ViewSnapshotHost.snapshotText(of: try menu(nameOverride: "Custom Name"))

        XCTAssertNotEqual(unpinned, pinned, "the pin flag must flip Pin↔Unpin")
        XCTAssertTrue(unpinned.contains("Pin Workspace"), "unpinned: Pin:\n\(unpinned)")
        XCTAssertTrue(pinned.contains("Unpin Workspace"), "pinned: Unpin:\n\(pinned)")

        XCTAssertNotEqual(unpinned, overridden, "a name override must add the revert arm")
        XCTAssertFalse(unpinned.contains("Remove Custom Workspace Name"), "no override: no revert:\n\(unpinned)")
        XCTAssertTrue(overridden.contains("Remove Custom Workspace Name"), "override: revert present:\n\(overridden)")
    }

    // MARK: - Determinism (P3)

    func testMenu_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, () throws -> String)] = [
            ("unpinned", { try ViewSnapshotHost.snapshotText(of: try self.menu(isPinned: false)) }),
            ("pinned", { try ViewSnapshotHost.snapshotText(of: try self.menu(isPinned: true)) }),
            ("override", { try ViewSnapshotHost.snapshotText(of: try self.menu(nameOverride: "Custom Name")) })
        ]
        for (name, make) in cases {
            let a = try make()
            let b = try make()
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }
}
#endif
