#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B1 — `WorkspaceTabStrip` (`:3309`) action-closure INTERACTION drive-to-100%.
///
/// The SU4 `TabStripSurfaceStateSetTests` snapshot the tab buttons + the filter-empty "Clear"
/// LABEL but never EXECUTE their actions, so the `select(_:)` helper (`L3324`), the tab `Button`'s
/// action (`L3407`), and the filter-empty "Clear" `Button` action (`L3385`) were uncovered. This
/// suite taps each → asserting its `@Published` side-effect, then MUTATION-VERIFIES the tab-select.
///
/// **Provenance (P2).** Tabs resolve through the REAL `WorkspaceSidebarPresentation` seam (saved
/// `WorkspaceState` → fresh VM `load()` → `activeWorkspaceRow` + `workspaceTabRows(for:)`); the
/// filter is set through the `@Published sidebarFilter` (the live `TextField` write). AN-001 hermetic.
///
/// **Determinism (P3).** Fixed ids; FIXED `/tmp/u5b1ts` working dir; no clock; `!contains("/Users/")`.
@MainActor
final class WorkspaceTabStripInteractionTests: XCTestCase {

    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000FE")!
    private static let wsA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000B1")!
    private static let tab1 = UUID(uuidString: "11111111-0000-0000-0000-0000000000B1")!
    private static let tab2 = UUID(uuidString: "22222222-0000-0000-0000-0000000000B2")!

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b1-ts-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private func tab(id: UUID, name: String) -> ProcessEntry {
        ProcessEntry(id: id, projectId: Self.projectId, name: name, kind: .shell,
                     executable: "/bin/zsh", workingDirectory: "/tmp/u5b1ts")
    }

    private func strip(_ model: WorkbenchViewModel) -> WorkspaceTabStrip {
        WorkspaceTabStrip(model: model)
    }

    private func twoTabModel() throws -> WorkbenchViewModel {
        let entries = [tab(id: Self.tab1, name: "build"), tab(id: Self.tab2, name: "test")]
        let workspaces = [Workspace(id: Self.wsA, autoName: "Frontend", tabIds: [Self.tab1, Self.tab2])]
        return try makeVM(state: WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"), processEntries: entries, workspaces: workspaces))
    }

    // MARK: - Tab select (the tabButton action → select(_:))

    func testTap_tabButton_selectsEntry() throws {
        let model = try twoTabModel()
        let active = try XCTUnwrap(model.activeWorkspaceRow)
        XCTAssertEqual(model.workspaceTabRows(for: active).count, 2, "provenance: two visible tabs")
        XCTAssertNil(model.selectedEntryID, "provenance: nothing selected yet")
        // The tab button renders its name `Text` + a11y `"<name>, <healthLabel>"`; find it by the
        // a11y label prefix for the "test" tab and tap → select(tab) sets selectedEntryID.
        try strip(model).inspect().find(ViewType.Button.self, where: { button in
            (try? button.accessibilityLabel().string())?.hasPrefix("test,") == true
        }).tap()
        XCTAssertEqual(model.selectedEntryID, Self.tab2, "tapping the 'test' tab selects its entry (select closure)")
    }

    // MARK: - Filter-empty "Clear" (the stripFilterEmptyState Clear action)

    func testTap_clearInFilterEmptyState_clearsFilter() throws {
        let model = try twoTabModel()
        model.sidebarFilter = "zzznomatch" // hides every tab → the FP4 filter-empty state + Clear
        let active = try XCTUnwrap(model.activeWorkspaceRow)
        XCTAssertTrue(model.workspaceTabRows(for: active).isEmpty, "provenance: the filter hid every tab")
        XCTAssertFalse(model.sidebarFilter.isEmpty, "provenance: a filter is set")
        try strip(model).inspect().find(button: "Clear").tap()
        XCTAssertTrue(model.sidebarFilter.isEmpty, "Clear empties the filter")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The tab-select action is load-bearing: tapping a tab sets selectedEntryID to THAT tab.
    /// (Mutation-verify: making `select(_:)` a no-op leaves selectedEntryID nil → RED.)
    func testNegativeControl_tabSelectSetsSelection() throws {
        let model = try twoTabModel()
        let before = model.selectedEntryID
        try strip(model).inspect().find(ViewType.Button.self, where: { button in
            (try? button.accessibilityLabel().string())?.hasPrefix("build,") == true
        }).tap()
        XCTAssertNotEqual(before, model.selectedEntryID, "the tab-select action must change the selection")
        XCTAssertEqual(model.selectedEntryID, Self.tab1, "select set the tapped tab's id")
    }

    // MARK: - Determinism (P3)

    func testStrip_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let a = try ViewSnapshotHost.snapshotText(of: strip(try twoTabModel()))
        let b = try ViewSnapshotHost.snapshotText(of: strip(try twoTabModel()))
        XCTAssertEqual(a, b, "the tab strip must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
    }
}
#endif
