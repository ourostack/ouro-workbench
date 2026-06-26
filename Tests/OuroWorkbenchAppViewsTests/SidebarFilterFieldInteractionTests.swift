#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B1 — `SidebarFilterField` (`:2946`) action-closure INTERACTION drive-to-100%.
///
/// The C1 `SidebarFilterFieldTests` snapshot the clear button + the suggestion chips but never
/// EXECUTE their actions, so the clear-button action (`L2965`, `model.sidebarFilter = ""`) and the
/// suggestion-chip action (`L2997`, `model.sidebarFilter = chip.token`) were uncovered. This suite
/// taps each → asserting the `@Published sidebarFilter` side-effect, then MUTATION-VERIFIES both.
///
/// **Provenance (P2).** The VM is built via the REAL store seam; the filter is read/written through
/// `@Published sidebarFilter` (the SAME binding the live `TextField` writes). AN-001 hermetic.
///
/// **Determinism (P3).** Fixed project; FIXED `/tmp/u5b1ff` rootPath; no clock; `!contains("/Users/")`.
@MainActor
final class SidebarFilterFieldInteractionTests: XCTestCase {

    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    private func makeVM(filter: String) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b1-ff-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: [WorkbenchProject(id: Self.projectId, name: "Frontend", rootPath: "/tmp/u5b1ff")]
        )
        try WorkbenchStore(paths: paths).save(state)
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
        model.sidebarFilter = filter
        return model
    }

    private func field(_ model: WorkbenchViewModel) -> SidebarFilterField {
        SidebarFilterField(model: model)
    }

    // MARK: - Clear button (the `!sidebarFilter.isEmpty` arm's Button action)

    func testTap_clearButton_emptiesFilter() throws {
        let model = try makeVM(filter: "build")
        XCTAssertFalse(model.sidebarFilter.isEmpty, "provenance: a typed filter → the clear button shows")
        try field(model).inspect().find(ViewType.Button.self, where: { button in
            (try? button.accessibilityLabel().string()) == "Clear session filter"
        }).tap()
        XCTAssertTrue(model.sidebarFilter.isEmpty, "the clear button empties the filter")
    }

    // MARK: - Suggestion chip (the empty-filter else arm's per-chip Button action)

    func testTap_suggestionChip_setsStructuredToken() throws {
        let model = try makeVM(filter: "")  // empty → the suggestion chips render
        XCTAssertTrue(model.sidebarFilter.isEmpty, "provenance: empty filter → chips render")
        // Tap the "Waiting" chip → model.sidebarFilter = "status:waiting".
        try field(model).inspect().find(button: "Waiting").tap()
        XCTAssertEqual(model.sidebarFilter, "status:waiting", "the Waiting chip inserts its structured token")
    }

    // MARK: - Negative controls (P2 — mutation-verified)

    /// The clear action is load-bearing: tapping it empties a non-empty filter. (Mutation-verify:
    /// removing `model.sidebarFilter = ""` leaves the filter unchanged → RED.)
    func testNegativeControl_clearActionEmptiesFilter() throws {
        let model = try makeVM(filter: "build")
        let before = model.sidebarFilter
        try field(model).inspect().find(ViewType.Button.self, where: { button in
            (try? button.accessibilityLabel().string()) == "Clear session filter"
        }).tap()
        XCTAssertNotEqual(before, model.sidebarFilter, "the clear action must change the filter")
        XCTAssertTrue(model.sidebarFilter.isEmpty, "and the new value is empty")
    }

    /// The chip action is load-bearing: tapping it sets the chip's token. (Mutation-verify: removing
    /// `model.sidebarFilter = chip.token` leaves the filter empty → RED.)
    func testNegativeControl_chipActionSetsToken() throws {
        let model = try makeVM(filter: "")
        let before = model.sidebarFilter
        try field(model).inspect().find(button: "Agent").tap()
        XCTAssertNotEqual(before, model.sidebarFilter, "the chip action must change the filter")
        XCTAssertEqual(model.sidebarFilter, "owner:agent", "the Agent chip inserts owner:agent")
    }
}
#endif
