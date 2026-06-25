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
        let source = try WorkbenchAppSource.appSource()
        XCTAssertTrue(
            source.contains("WorkspaceRowContextMenu(row: row, model: model)"),
            "the WorkspaceSidebarRow must attach the ②d workspace context menu"
        )
    }

    func testWorkspaceContextMenuHasPinRenameAndRemoveCustomName() throws {
        let source = try WorkbenchAppSource.appSource()
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
        let source = try WorkbenchAppSource.appSource()
        // D2d-2 — the item is shown ONLY when an override exists. The gate reads the
        // row's nameOverride (added to WorkspaceRow in Unit 4b).
        XCTAssertTrue(
            source.contains("if row.nameOverride != nil"),
            "Remove Custom Workspace Name is conditional on row.nameOverride != nil (D2d-2)"
        )
    }

    func testRenameWorkspaceChordTargetsActiveWorkspace() throws {
        let source = try WorkbenchAppSource.appSource()
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
        let source = try WorkbenchAppSource.appSource()
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
        let pinWrapper = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "func toggleWorkspacePin(_ id: UUID)",
            to: "func renameWorkspace(_ id: UUID, to input: String)"
        )
        XCTAssertTrue(
            pinWrapper.contains("state.toggleWorkspacePin(workspaceId: id)") && pinWrapper.contains("save()"),
            "toggleWorkspacePin wrapper must call the Core mutator then persist via save()"
        )
        let renameWrapper = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "func renameWorkspace(_ id: UUID, to input: String)",
            to: "func removeCustomWorkspaceName(_ id: UUID)"
        )
        XCTAssertTrue(
            renameWrapper.contains("state.setWorkspaceNameOverride(workspaceId: id, to:") && renameWrapper.contains("save()"),
            "renameWorkspace wrapper must set the override then persist via save()"
        )
        let removeWrapper = try WorkbenchAppSource.sourceSlice(
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
        let source = try WorkbenchAppSource.appSource()
        XCTAssertTrue(
            source.contains("WorkspaceTabContextMenu(tab: tab, model: model)"),
            "the WorkspaceTabStrip tabButton must attach the ②d tab context menu"
        )
    }

    func testTabContextMenuHasRenameTab() throws {
        let source = try WorkbenchAppSource.appSource()
        XCTAssertTrue(
            source.contains("model.beginRename(.tab(tab.id), prefill: tab.effectiveTabName)"),
            "Rename Tab must begin the inline rename on the tab target, prefilled with effectiveTabName"
        )
    }

    func testRenameTabChordTargetsSelectedTab() throws {
        let source = try WorkbenchAppSource.appSource()
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
        let source = try WorkbenchAppSource.appSource()
        let renameTabWrapper = try WorkbenchAppSource.sourceSlice(
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

    // MARK: - Unit 6: inline rename editors + caption + commit routing

    func testWorkspaceRowShowsInlineEditorWhenEditing() throws {
        let source = try WorkbenchAppSource.appSource()
        XCTAssertTrue(
            source.contains("model.inlineRename.isEditing(.workspace(row.id))"),
            "the workspace row must swap its label for the editor while that workspace is being renamed"
        )
    }

    func testTabButtonShowsInlineEditorWhenEditing() throws {
        let source = try WorkbenchAppSource.appSource()
        XCTAssertTrue(
            source.contains("model.inlineRename.isEditing(.tab(tab.id))"),
            "the tab button must swap its label for the editor while that tab is being renamed"
        )
    }

    func testInlineEditorBindsDraftAndCommitsOnSubmit() throws {
        let source = try WorkbenchAppSource.appSource()
        // The editor's TextField is bound to the inline-rename draft …
        XCTAssertTrue(
            source.contains("$model.inlineRename.draft"),
            "the inline editor TextField must bind to the inline-rename draft"
        )
        // … Enter commits …
        XCTAssertTrue(
            source.contains(".onSubmit { model.commitRename() }"),
            "Enter (.onSubmit) must commit the rename"
        )
    }

    func testInlineEditorCancelsOnExitCommand() throws {
        let source = try WorkbenchAppSource.appSource()
        // Review note 3 — ONE Escape mechanism, asserted EXACTLY (not a vacuous
        // any-of-three). We use `.onExitCommand` (the AppKit Escape hook).
        XCTAssertTrue(
            source.contains(".onExitCommand { model.cancelRename() }"),
            "Escape (.onExitCommand) must cancel the rename"
        )
    }

    func testInlineEditorShowsHelperCaption() throws {
        let source = try WorkbenchAppSource.appSource()
        XCTAssertTrue(
            source.contains("Press Enter to rename, Escape to cancel."),
            "the inline editor must show the cmux helper caption"
        )
    }

    func testCommitRenameDispatchesPerActiveTarget() throws {
        let source = try WorkbenchAppSource.appSource()
        // commitRename pulls the pending commit from InlineRenameState and dispatches to
        // the per-target wrapper (which itself routes through WorkspaceRenameCommit; D2d-1).
        let commitFn = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "func commitRename()",
            to: "func cancelRename()"
        )
        XCTAssertTrue(
            commitFn.contains("inlineRename.commit()"),
            "commitRename must pull the pending commit from InlineRenameState"
        )
        XCTAssertTrue(
            commitFn.contains("renameWorkspace(") && commitFn.contains("renameTab("),
            "commitRename must dispatch to renameWorkspace / renameTab per the active target"
        )
        let cancelFn = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "func cancelRename()",
            to: "}"
        )
        XCTAssertTrue(
            cancelFn.contains("inlineRename.cancel()"),
            "cancelRename must cancel the InlineRenameState"
        )
    }

    // MARK: - Source-guard helpers (copied verbatim from WorkspaceSidebarWiringTests)
}
