import XCTest
@testable import OuroWorkbenchCore

/// Slice ②b — source-level regression guard for the sidebar + cmux tab-strip rewire.
///
/// App SwiftUI views are NOT XCTest-visible, so (exactly as Slice ① and the existing
/// `*WiringTests`) we pin the wiring against the App source string: the NEW
/// workspace-rows + tab-strip render must be present, and the OLD
/// projects-as-workspaces / "Terminals in <name>" / PWD-dump surface must be gone,
/// while the Archived + Recovery sections are preserved.
final class WorkspaceSidebarWiringTests: XCTestCase {

    // MARK: - NEW wiring present: the sidebar renders state.workspaces via the seam

    func testSidebarRendersWorkspacesThroughThePresentationSeam() throws {
        let source = try WorkbenchAppSource.appSource()
        // The sidebar wires the pure Core seam in (the only place grouping/ordering
        // is derived), reading state.workspaces — never a re-derived flat list.
        XCTAssertTrue(
            source.contains("WorkspaceSidebarPresentation.resolve("),
            "the sidebar must derive its rows from the WorkspaceSidebarPresentation seam"
        )
        XCTAssertTrue(
            source.contains("workspaces: state.workspaces"),
            "the seam must be fed the persisted state.workspaces (②a structure) — not a re-derived flat list"
        )
        // The Workspaces section header keeps using the surface-policy constant.
        XCTAssertTrue(
            source.contains("Section(WorkbenchSurfacePolicy.workspaceSectionTitle)"),
            "the Workspaces section header stays wired through WorkbenchSurfacePolicy"
        )
    }

    // MARK: - OLD wiring gone: projects-as-workspaces + PWD dump + Terminals-in section

    func testOldProjectsAsWorkspacesSurfaceIsGone() throws {
        let source = try WorkbenchAppSource.appSource()
        XCTAssertFalse(
            source.contains("ForEach(model.state.projects) { project in\n                    SidebarProjectRow("),
            "the projects-as-workspaces ForEach/SidebarProjectRow sidebar section must be gone"
        )
        XCTAssertFalse(
            source.contains("SidebarProjectRow("),
            "SidebarProjectRow (the projects-as-workspaces row) must no longer be rendered"
        )
        XCTAssertFalse(
            source.contains("Text(project.rootPath)"),
            "the PWD dump Text(project.rootPath) must be gone from the sidebar render path"
        )
    }

    func testTerminalsInHomeSectionIsGone() throws {
        let source = try WorkbenchAppSource.appSource()
        XCTAssertFalse(
            source.contains("Section(WorkbenchSurfacePolicy.terminalsSectionTitle(workspaceName: model.selectedProject?.name))"),
            "the 'Terminals in <name>' sidebar section must be removed (tabs move to the top strip)"
        )
        XCTAssertFalse(
            source.contains("ForEach(model.sessionEntries) { entry in"),
            "the flat-list-scoped-to-selected-project sidebar render must be gone"
        )
    }

    func testNewWorkspaceActionRowIsRemoved() throws {
        // DB8: the sidebar 'New Workspace' action row (which created a WorkbenchProject,
        // a model mismatch once rows are Workspaces) is removed in ②b; manual create is ②d.
        let source = try WorkbenchAppSource.appSource()
        XCTAssertFalse(
            source.contains("SidebarActionRow(title: WorkbenchSurfacePolicy.newWorkspaceTitle"),
            "the 'New Workspace' action row must be removed from the sidebar (DB8)"
        )
    }

    // MARK: - FIX PASS (FP5): lean-cmux — nested per-tab rows GONE from the sidebar

    func testSidebarHasNoNestedPerTabRows() throws {
        // LEAN-CMUX: the sidebar shows ONLY lean workspace rows (+ empty marker) — the
        // per-tab TerminalAgentRow ForEach (model.workspaceTabRows) is removed from the
        // Workspaces section. Tabs live solely in the top strip (WorkspaceTabStrip).
        let source = try WorkbenchAppSource.appSource()
        XCTAssertFalse(
            source.contains("ForEach(model.workspaceTabRows(for: row))"),
            "the nested per-tab TerminalAgentRow ForEach must be removed from the sidebar (tabs live in the top strip)"
        )
    }

    func testSidebarStillRendersLeanWorkspaceRows() throws {
        // The lean workspace row + empty marker stay (the sidebar's only workspace content).
        let source = try WorkbenchAppSource.appSource()
        XCTAssertTrue(
            source.contains("WorkspaceSidebarRow(row: row, model: model)"),
            "the lean WorkspaceSidebarRow must still render per workspace"
        )
        XCTAssertTrue(
            source.contains("SidebarWorkspaceEmptyRow()"),
            "the empty-workspace marker must still render"
        )
    }

    // MARK: - FIX PASS (FP4+FP5): the filtered empty-state lives in the STRIP

    func testTabStripAppliesTheFilterAndShowsFilteredEmptyState() throws {
        let source = try WorkbenchAppSource.appSource()
        let strip = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "struct WorkspaceTabStrip: View",
            to: "\n}\n"
        )
        // The strip renders the active workspace's FILTERED tabs (via workspaceTabRows,
        // which applies SidebarSessionFilter), not the raw unfiltered ResolvedTabs.
        XCTAssertTrue(
            strip.contains("workspaceTabRows(for:"),
            "the strip must render the active workspace's FILTERED tabs"
        )
        // The strip shows the filter empty-state via the pure Core decision, tested
        // against the FILTERED count (FP4).
        XCTAssertTrue(
            strip.contains("stripFilterHidAllTabs"),
            "the strip must decide the filter empty-state via the pure Core seam (filtered count)"
        )
    }

    func testSidebarNoLongerCarriesTheFilterEmptyStateRow() throws {
        // FP4/FP5: the filter empty-state moved from the sidebar Workspaces section to
        // the strip. The old sidebar guard (allSatisfy on UNFILTERED row.tabs) is gone.
        let source = try WorkbenchAppSource.appSource()
        XCTAssertFalse(
            source.contains("model.workspaceSidebarModel.rows.allSatisfy(\\.tabs.isEmpty)"),
            "the unfiltered-tabs sidebar filter empty-state guard must be removed (it moved to the strip, tested on the filtered list)"
        )
    }

    // MARK: - FIX PASS (FP6): dead "New Workspace" group sheet + flag removed

    func testDeadNewGroupSheetAndFlagAreRemoved() throws {
        // DB8 removed the "New Workspace" trigger, so `isNewGroupSheetPresented` + its
        // `.sheet` became unreachable. Remove the orphaned sheet presentation + flag.
        // (The `NewTerminalGroupSheet` struct itself stays — still guarded by
        // WorkspaceNameDerivationTests and internal, so no unused-symbol warning.)
        let source = try WorkbenchAppSource.appSource()
        XCTAssertFalse(
            source.contains("isNewGroupSheetPresented"),
            "the unreachable isNewGroupSheetPresented flag + its .sheet must be removed (DB8 left no trigger)"
        )
    }

    // MARK: - KEEP present: Archived + Recovery sections preserved through the rewire

    func testArchivedAndRecoverySectionsArePreserved() throws {
        let source = try WorkbenchAppSource.appSource()
        XCTAssertTrue(
            source.contains("if !model.archivedSessionEntries.isEmpty {"),
            "the Archived section must still render after the rewire"
        )
        XCTAssertTrue(
            source.contains("Section(\"Archived\")"),
            "the Archived section header must be preserved"
        )
        XCTAssertTrue(
            source.contains("WorkbenchSurfacePolicy.shouldShowRecovery(recoverableCount: model.recoveryDigest.actionableCount)"),
            "the Recovery section gate must be preserved"
        )
        XCTAssertTrue(
            source.contains("Section(\"Recovery\")"),
            "the Recovery section header must be preserved"
        )
    }

    // MARK: - Unit 3: cmux tab-strip in the detail column

    func testDetailColumnMountsTheActiveWorkspaceTabStrip() throws {
        let source = try WorkbenchAppSource.appSource()
        // A dedicated tab-strip view renders the active workspace's tabs across the
        // top of the detail column (cmux layout).
        XCTAssertTrue(
            source.contains("struct WorkspaceTabStrip: View"),
            "a WorkspaceTabStrip view must exist for the cmux tab-strip"
        )
        XCTAssertTrue(
            source.contains("WorkspaceTabStrip(model: model)"),
            "the detail column must mount the WorkspaceTabStrip"
        )
    }

    func testTabStripSourcesTabsFromThePresentationSeamNotAReDerivedFlatList() throws {
        let source = try WorkbenchAppSource.appSource()
        let strip = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "struct WorkspaceTabStrip: View",
            to: "\n}\n"
        )
        // The strip reads the seam's active workspace (model.activeWorkspaceRow), not a
        // re-derived flat session list.
        XCTAssertTrue(
            strip.contains("model.activeWorkspaceRow"),
            "the tab-strip must source its tabs from the WorkspaceSidebarPresentation active workspace"
        )
        // It names tabs by effectiveTabName (carried by the seam's ResolvedTab).
        XCTAssertTrue(
            strip.contains("effectiveTabName"),
            "the tab-strip must label tabs by effectiveTabName"
        )
        // Selecting a tab sets selectedEntryID.
        XCTAssertTrue(
            strip.contains("model.selectedEntryID ="),
            "selecting a tab in the strip must set selectedEntryID"
        )
    }

    func testTabStripMountsBetweenBossDashboardAndDetailGroup() throws {
        let source = try WorkbenchAppSource.appSource()
        // The strip sits above the session detail Group, below the Boss dashboard
        // divider — the cmux "tabs across the top" position.
        let stripMount = try XCTUnwrap(source.range(of: "WorkspaceTabStrip(model: model)"))
        let detailGroup = try XCTUnwrap(
            source.range(of: "DetailSplitContainer(primaryEntry: entry, model: model)")
        )
        XCTAssertLessThan(
            stripMount.lowerBound, detailGroup.lowerBound,
            "the tab-strip must mount ABOVE the session-detail Group (tabs-across-the-top)"
        )
    }

    // MARK: - Helpers
}
