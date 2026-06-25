#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// SU4 — Surface B (tab-strip) COMPLETE enumerated state-set on `WorkspaceTabStrip`
/// (campaign §Surfaces B): no-active-ws (nil → empty tree); empty-ws "— no tabs yet";
/// filtered-to-empty "No sessions match…" + "Clear" (the FP4 boundary, DISTINCT from
/// genuinely-empty); one tab; many tabs; selected-vs-not (", selected"); tab-rename
/// (`InlineRenameEditor` swapped in). BOUNDARY (FP4): filter-empty vs genuinely-empty
/// are two DISTINCT references.
///
/// Independent of SU0 (no tab embeds a clock/elapsed read — the tab-strip renders
/// `tab.effectiveTabName` + the `tab.attention` health glyph, never `runningSince`)
/// and of SU1 (no editable bound-value here except the rename `TextField`, whose value
/// is the rename draft).
///
/// Every fixture is provenance-built via the REAL seam: `WorkbenchStore(paths:).save(state)`
/// → a fresh `WorkbenchViewModel` whose `load()` derives `activeWorkspaceRow` +
/// `workspaceTabRows(for:)` through the pure `WorkspaceSidebarPresentation.resolve` +
/// `stripFilterHidAllTabs` seams — NEVER hand-assembled (P2). Each VM injects a temp
/// `agentBundlesURL` (AN-001). The provenance-preservation facts (bootstrap/reconcile/
/// migrate are no-ops on fully-mapped `.shell` fixtures with no `processRuns`) are the
/// same as `SidebarSurfaceStateSetTests`.
@MainActor
final class TabStripSurfaceStateSetTests: XCTestCase {

    // MARK: - Hermetic provenance fixture (AN-001-safe)

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("su4-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private func strip(_ model: WorkbenchViewModel) -> WorkspaceTabStrip {
        WorkspaceTabStrip(model: model)
    }

    private func tab(id: UUID, name: String, attention: AttentionState = .idle, tabNameOverride: String? = nil) -> ProcessEntry {
        ProcessEntry(
            id: id,
            projectId: Self.projectId,
            name: name,
            kind: .shell,
            executable: "/bin/zsh",
            workingDirectory: "/tmp/su4",
            attention: attention,
            tabNameOverride: tabNameOverride
        )
    }

    private func state(workspaces: [Workspace], entries: [ProcessEntry]) -> WorkspaceState {
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            processEntries: entries,
            workspaces: workspaces
        )
    }

    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000FE")!
    private static let wsA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000B1")!
    private static let tab1 = UUID(uuidString: "11111111-0000-0000-0000-0000000000B1")!
    private static let tab2 = UUID(uuidString: "22222222-0000-0000-0000-0000000000B2")!
    private static let tab3 = UUID(uuidString: "33333333-0000-0000-0000-0000000000B3")!

    // MARK: - no-active-ws (nil → empty tree)

    func testB_noActiveWorkspace() throws {
        // No workspaces → `activeWorkspaceRow == nil` → the strip body renders NOTHING.
        let model = try makeVM(state: state(workspaces: [], entries: []))
        XCTAssertNil(model.activeWorkspaceRow, "provenance: no active workspace")
        try assertViewSnapshot(of: strip(model), named: "B.noActiveWorkspace")
    }

    // MARK: - empty-ws "— no tabs yet" (genuinely empty)

    func testB_emptyWorkspace() throws {
        // The active workspace has zero tabs, no filter → "<name> — no tabs yet".
        let workspaces = [Workspace(id: Self.wsA, autoName: "Scratch", tabIds: [])]
        let model = try makeVM(state: state(workspaces: workspaces, entries: []))
        let active = try XCTUnwrap(model.activeWorkspaceRow)
        XCTAssertTrue(model.workspaceTabRows(for: active).isEmpty, "provenance: zero tabs, no filter")
        XCTAssertFalse(model.sidebarFilterIsActive, "provenance: no filter active")
        try assertViewSnapshot(of: strip(model), named: "B.emptyWorkspace")
    }

    // MARK: - filtered-to-empty "No sessions match…" + Clear (the FP4 boundary)

    func testB_filteredToEmpty() throws {
        // A NON-empty workspace (1 tab) whose active filter hides EVERY tab →
        // `stripFilterHidAll` true → the "No sessions match \"<query>\"" + Clear state.
        // DISTINCT from a genuinely-empty workspace (B.emptyWorkspace).
        let entries = [tab(id: Self.tab1, name: "build")]
        let workspaces = [Workspace(id: Self.wsA, autoName: "Frontend", tabIds: [Self.tab1])]
        let model = try makeVM(state: state(workspaces: workspaces, entries: entries))
        model.sidebarFilter = "zzznomatch" // a free-text query no tab/workspace name contains
        let active = try XCTUnwrap(model.activeWorkspaceRow)
        XCTAssertTrue(model.sidebarFilterIsActive, "provenance: filter active")
        XCTAssertEqual(active.tabs.count, 1, "provenance: the workspace genuinely has 1 tab")
        XCTAssertTrue(model.workspaceTabRows(for: active).isEmpty, "provenance: the filter hid it")
        XCTAssertTrue(WorkspaceSidebarPresentation.stripFilterHidAllTabs(
            tabsBeforeFilter: active.tabs.count, tabsAfterFilter: 0, filterActive: true),
            "provenance: the FP4 filter-hid-all decision is true")
        try assertViewSnapshot(of: strip(model), named: "B.filteredToEmpty")
    }

    // MARK: - one / many tabs

    func testB_oneTab() throws {
        let entries = [tab(id: Self.tab1, name: "main", attention: .active)]
        let workspaces = [Workspace(id: Self.wsA, autoName: "Frontend", tabIds: [Self.tab1])]
        let model = try makeVM(state: state(workspaces: workspaces, entries: entries))
        try assertViewSnapshot(of: strip(model), named: "B.oneTab")
    }

    func testB_manyTabs() throws {
        // Three tabs with distinct names + health states; one carries a tabNameOverride
        // (effectiveTabName shows the override).
        let entries = [
            tab(id: Self.tab1, name: "build", attention: .idle),
            tab(id: Self.tab2, name: "test", attention: .waitingOnHuman),
            tab(id: Self.tab3, name: "auto-deploy", attention: .active, tabNameOverride: "Deploy")
        ]
        let workspaces = [Workspace(id: Self.wsA, autoName: "Frontend", tabIds: [Self.tab1, Self.tab2, Self.tab3])]
        let model = try makeVM(state: state(workspaces: workspaces, entries: entries))
        let active = try XCTUnwrap(model.activeWorkspaceRow)
        XCTAssertEqual(model.workspaceTabRows(for: active).map(\.resolved.effectiveTabName),
                       ["build", "test", "Deploy"], "provenance: 3 tabs, override resolved")
        try assertViewSnapshot(of: strip(model), named: "B.manyTabs")
    }

    // MARK: - selected vs not

    func testB_selected() throws {
        // Selecting a tab (the real `selectedEntryID` seam) adds ", selected" to its
        // accessibility label. Two tabs so the selected one is distinguishable.
        let entries = [tab(id: Self.tab1, name: "build"), tab(id: Self.tab2, name: "test")]
        let workspaces = [Workspace(id: Self.wsA, autoName: "Frontend", tabIds: [Self.tab1, Self.tab2])]
        let model = try makeVM(state: state(workspaces: workspaces, entries: entries))
        model.selectedEntryID = Self.tab1
        try assertViewSnapshot(of: strip(model), named: "B.selected")
    }

    // MARK: - tab-rename

    func testB_tabRenameInProgress() throws {
        // Put a tab into rename mode → `tabButton` swaps in `InlineRenameEditor`.
        let entries = [tab(id: Self.tab1, name: "renaming-tab")]
        let workspaces = [Workspace(id: Self.wsA, autoName: "Frontend", tabIds: [Self.tab1])]
        let model = try makeVM(state: state(workspaces: workspaces, entries: entries))
        model.beginRename(.tab(Self.tab1), prefill: "renaming-tab")
        XCTAssertTrue(model.inlineRename.isEditing(.tab(Self.tab1)), "provenance: the tab is in rename mode")
        try assertViewSnapshot(of: strip(model), named: "B.tabRenameInProgress")
    }

    // MARK: - Negative controls (P2)

    /// NEGATIVE CONTROL #1 (the two-distinct-empty-states boundary, FP4) — a
    /// genuinely-empty workspace ("— no tabs yet") and a filter-hid-all workspace
    /// ("No sessions match…") produce DIFFERENT trees. This is the boundary P4e cares
    /// about most: the two empty states must NOT be byte-identical.
    func testB_negativeControl_filterEmptyDiffersFromGenuinelyEmpty() throws {
        let genuinelyEmpty = try ViewSnapshotHost.snapshotText(of: strip(try makeVM(
            state: state(workspaces: [Workspace(id: Self.wsA, autoName: "Scratch", tabIds: [])], entries: []))))

        let filterHidAllModel = try makeVM(state: state(
            workspaces: [Workspace(id: Self.wsA, autoName: "Frontend", tabIds: [Self.tab1])],
            entries: [tab(id: Self.tab1, name: "build")]))
        filterHidAllModel.sidebarFilter = "zzznomatch"
        let filterEmpty = try ViewSnapshotHost.snapshotText(of: strip(filterHidAllModel))

        XCTAssertNotEqual(genuinelyEmpty, filterEmpty,
                          "filter-empty and genuinely-empty must be DISTINCT states (FP4)")
        XCTAssertTrue(genuinelyEmpty.contains("— no tabs yet"), "genuinely-empty marker:\n\(genuinelyEmpty)")
        XCTAssertFalse(genuinelyEmpty.contains("No sessions match"), "genuinely-empty has no filter copy")
        XCTAssertTrue(filterEmpty.contains(#"No sessions match "zzznomatch""#), "filter copy:\n\(filterEmpty)")
        XCTAssertTrue(filterEmpty.contains("Clear"), "filter state offers Clear:\n\(filterEmpty)")
    }

    /// NEGATIVE CONTROL #2 — selecting a different tab, and changing the filter so it
    /// flips between hiding-all and matching, both flip the tree.
    func testB_negativeControl_selectionAndFilterFlipTree() throws {
        let entries = [tab(id: Self.tab1, name: "build"), tab(id: Self.tab2, name: "test")]
        let workspaces = [Workspace(id: Self.wsA, autoName: "Frontend", tabIds: [Self.tab1, Self.tab2])]

        func tree(selected: UUID?, filter: String) throws -> String {
            let model = try makeVM(state: state(workspaces: workspaces, entries: entries))
            model.selectedEntryID = selected
            model.sidebarFilter = filter
            return try ViewSnapshotHost.snapshotText(of: strip(model))
        }
        let selectFirst = try tree(selected: Self.tab1, filter: "")
        let selectSecond = try tree(selected: Self.tab2, filter: "")
        XCTAssertNotEqual(selectFirst, selectSecond, "selecting a different tab must flip the tree")

        let unfiltered = try tree(selected: nil, filter: "")
        let filterMatchesOne = try tree(selected: nil, filter: "build")
        XCTAssertNotEqual(unfiltered, filterMatchesOne, "a filter that hides one tab must flip the tree")
        XCTAssertTrue(filterMatchesOne.contains(#"text="build""#), filterMatchesOne)
        XCTAssertFalse(filterMatchesOne.contains(#"text="test""#),
                       "the filter hides the non-matching tab:\n\(filterMatchesOne)")
    }

    // MARK: - Determinism (P3)

    func testB_determinism_eachFixtureByteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, () throws -> String)] = [
            ("nil", { try ViewSnapshotHost.snapshotText(of: self.strip(try self.makeVM(
                state: self.state(workspaces: [], entries: [])))) }),
            ("many", {
                try ViewSnapshotHost.snapshotText(of: self.strip(try self.makeVM(state: self.state(
                    workspaces: [Workspace(id: Self.wsA, autoName: "Frontend", tabIds: [Self.tab1, Self.tab2])],
                    entries: [self.tab(id: Self.tab1, name: "build"), self.tab(id: Self.tab2, name: "test", attention: .waitingOnHuman)]))))
            }),
            ("filterEmpty", {
                let m = try self.makeVM(state: self.state(
                    workspaces: [Workspace(id: Self.wsA, autoName: "Frontend", tabIds: [Self.tab1])],
                    entries: [self.tab(id: Self.tab1, name: "build")]))
                m.sidebarFilter = "zzznomatch"
                return try ViewSnapshotHost.snapshotText(of: self.strip(m))
            })
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
