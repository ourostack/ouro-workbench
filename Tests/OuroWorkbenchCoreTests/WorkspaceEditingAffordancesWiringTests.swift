import XCTest
@testable import OuroWorkbenchCore

/// Slice ②d — source-level regression guard for the in-app editing affordances
/// (workspace + tab context menus, the ⇧⌘R/⌘R rename chords, and the inline rename
/// editors). App SwiftUI is NOT XCTest-visible, so — exactly as Slices ①/②b and the
/// existing `*WiringTests` — the wiring is pinned against the App source string. The
/// testable LOGIC lives in the pure Core seams (`WorkspaceState` mutators,
/// `WorkspaceRenameCommit`, `InlineRenameState`), which are real red→green XCTests
/// elsewhere; THIS file only proves the SwiftUI surface calls into them.
final class WorkspaceEditingAffordancesWiringTests: XCTestCase {

    // MARK: - Unit 4: workspace context menu + thin VM wrappers

    func testWorkspaceRowAttachesAContextMenu() throws {
        let source = try appSource()
        XCTAssertTrue(
            source.contains("WorkspaceRowContextMenu(row: row, model: model)"),
            "the WorkspaceSidebarRow must attach the ②d workspace context menu"
        )
    }

    func testWorkspaceContextMenuHasPinRenameAndRemoveCustomName() throws {
        let source = try appSource()
        // Pin/Unpin (label flips on row.isPinned; pin / pin.slash icon).
        XCTAssertTrue(
            source.contains("model.toggleWorkspacePin(row.id)"),
            "the workspace menu must offer Pin/Unpin wired to the VM wrapper"
        )
        XCTAssertTrue(
            source.contains("row.isPinned ? \"Unpin Workspace\" : \"Pin Workspace\""),
            "the Pin/Unpin label flips on row.isPinned"
        )
        // Rename Workspace… opens the inline editor on the workspace target.
        XCTAssertTrue(
            source.contains("model.beginRename(.workspace(row.id), prefill: row.effectiveName)"),
            "Rename Workspace must begin the inline rename on the workspace target, prefilled with effectiveName"
        )
        // Remove Custom Workspace Name clears the override (→ revert to autoName).
        XCTAssertTrue(
            source.contains("model.removeCustomWorkspaceName(row.id)"),
            "Remove Custom Workspace Name must call the clear wrapper"
        )
    }

    func testRemoveCustomNameItemIsGatedOnNameOverridePresent() throws {
        let source = try appSource()
        // D2d-2 — the item is shown ONLY when an override exists. The gate reads the
        // row's nameOverride (added to WorkspaceRow in Unit 4b).
        XCTAssertTrue(
            source.contains("if row.nameOverride != nil"),
            "Remove Custom Workspace Name is conditional on row.nameOverride != nil (D2d-2)"
        )
    }

    func testRenameWorkspaceChordTargetsActiveWorkspace() throws {
        let source = try appSource()
        // D2d-8 — ⇧⌘R is wired via the chord dispatcher and targets the ACTIVE workspace.
        XCTAssertTrue(
            source.contains("menuCommand(\"Rename Workspace…\", .renameWorkspace, \"r\", [.command, .shift])"),
            "the ⇧⌘R Rename Workspace chord must be registered in the command menu"
        )
        XCTAssertTrue(
            source.contains("case .renameWorkspace:"),
            "the chord dispatcher must handle .renameWorkspace"
        )
        XCTAssertTrue(
            source.contains("model.beginRenameActiveWorkspace()"),
            "the ⇧⌘R chord must begin-rename the active workspace"
        )
    }

    func testWorkspaceWrappersCallCoreMutatorsThenSave() throws {
        let source = try appSource()
        // The thin VM wrappers mutate state via the Core mutators then persist via save().
        XCTAssertTrue(
            source.contains("state.toggleWorkspacePin(workspaceId: id)"),
            "toggleWorkspacePin wrapper must call the Core mutator"
        )
        XCTAssertTrue(
            source.contains("state.setWorkspaceNameOverride(workspaceId: id, to:"),
            "renameWorkspace wrapper must call setWorkspaceNameOverride"
        )
        XCTAssertTrue(
            source.contains("state.clearWorkspaceNameOverride(workspaceId: id)"),
            "removeCustomWorkspaceName wrapper must call clearWorkspaceNameOverride"
        )
        // Each wrapper persists. Pin a precise slice (from the wrapper signature to the
        // NEXT wrapper signature) so this is not a vacuous match: the call to the Core
        // mutator and the trailing save() must BOTH live inside the same wrapper body.
        let pinWrapper = try sourceSlice(
            in: source,
            from: "func toggleWorkspacePin(_ id: UUID)",
            to: "func renameWorkspace(_ id: UUID, to input: String)"
        )
        XCTAssertTrue(
            pinWrapper.contains("state.toggleWorkspacePin(workspaceId: id)") && pinWrapper.contains("save()"),
            "toggleWorkspacePin wrapper must call the Core mutator then persist via save()"
        )
        let renameWrapper = try sourceSlice(
            in: source,
            from: "func renameWorkspace(_ id: UUID, to input: String)",
            to: "func removeCustomWorkspaceName(_ id: UUID)"
        )
        XCTAssertTrue(
            renameWrapper.contains("state.setWorkspaceNameOverride(workspaceId: id, to:") && renameWrapper.contains("save()"),
            "renameWorkspace wrapper must set the override then persist via save()"
        )
        let removeWrapper = try sourceSlice(
            in: source,
            from: "func removeCustomWorkspaceName(_ id: UUID)",
            to: "func beginRename("
        )
        XCTAssertTrue(
            removeWrapper.contains("state.clearWorkspaceNameOverride(workspaceId: id)") && removeWrapper.contains("save()"),
            "removeCustomWorkspaceName wrapper must clear the override then persist via save()"
        )
    }

    // MARK: - Unit 5: tab context menu + thin VM wrapper

    func testTabButtonAttachesAContextMenu() throws {
        let source = try appSource()
        XCTAssertTrue(
            source.contains("WorkspaceTabContextMenu(tab: tab, model: model)"),
            "the WorkspaceTabStrip tabButton must attach the ②d tab context menu"
        )
    }

    func testTabContextMenuHasRenameTab() throws {
        let source = try appSource()
        XCTAssertTrue(
            source.contains("model.beginRename(.tab(tab.id), prefill: tab.effectiveTabName)"),
            "Rename Tab must begin the inline rename on the tab target, prefilled with effectiveTabName"
        )
    }

    func testRenameTabChordTargetsSelectedTab() throws {
        let source = try appSource()
        // D2d-8 — ⌘R is wired via the chord dispatcher and targets the SELECTED tab.
        XCTAssertTrue(
            source.contains("menuCommand(\"Rename Tab…\", .renameTab, \"r\")"),
            "the ⌘R Rename Tab chord must be registered in the command menu"
        )
        XCTAssertTrue(
            source.contains("case .renameTab:"),
            "the chord dispatcher must handle .renameTab"
        )
        XCTAssertTrue(
            source.contains("model.beginRenameSelectedTab()"),
            "the ⌘R chord must begin-rename the selected tab"
        )
    }

    func testRenameTabWrapperCallsCoreMutatorThenSave() throws {
        let source = try appSource()
        let renameTabWrapper = try sourceSlice(
            in: source,
            from: "func renameTab(_ id: UUID, to input: String)",
            to: "func beginRename("
        )
        XCTAssertTrue(
            renameTabWrapper.contains("WorkspaceRenameCommit.resolve(input: input, current:")
                && renameTabWrapper.contains("state.setTabNameOverride(tabId: id, to:")
                && renameTabWrapper.contains("save()"),
            "renameTab wrapper must route through WorkspaceRenameCommit, set the tab override, then save()"
        )
    }

    // MARK: - Source-guard helpers (copied verbatim from WorkspaceSidebarWiringTests)

    private func sourceSlice(in source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let end = try XCTUnwrap(source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound)
        return String(source[start..<end])
    }

    private func appSource() throws -> String {
        let sourceURL = repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("OuroWorkbenchApp")
            .appendingPathComponent("OuroWorkbenchApp.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
