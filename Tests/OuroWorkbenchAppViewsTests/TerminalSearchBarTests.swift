#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B4 — `TerminalSearchBar` (20 uncovered regions: the whole search-bar body +
/// the conditional "No matches" arm were never driven by the campaign).
///
/// Every rendered region binds to the VM's `@Published` terminal-search state — a real
/// seam. We drive BOTH arms of the conditional "No matches" badge:
///   - default (query empty, `terminalSearchHasResult == true`) → the badge is absent;
///   - `query == "missing"`, `terminalSearchHasResult == false` → the
///     `!hasResult && !query.isEmpty` arm renders the "No matches" Text.
/// The captured `TextField` bound value tracks `terminalSearchQuery` (the data-driven
/// discriminator), and the three `TerminalSearchToggleButton`s (Aa / .* / Wˌ) + the
/// chevrons + Done render statically.
///
/// **Genuinely-unreachable (recorded carve candidates, NOT driven):** the `.onSubmit`,
/// `.onChange`, the chevron/Done/toggle button ACTION closures, and the `.onAppear`
/// focus closure are never invoked by a render pass. Recorded for Unit 3.
@MainActor
final class TerminalSearchBarTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b4search-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    /// A VM whose terminal-search state is set through its real `@Published` seam.
    private func vm(query: String, hasResult: Bool) throws -> WorkbenchViewModel {
        let model = try makeVM()
        model.terminalSearchQuery = query
        model.terminalSearchHasResult = hasResult
        return model
    }

    private func bar(query: String, hasResult: Bool) throws -> TerminalSearchBar {
        TerminalSearchBar(model: try vm(query: query, hasResult: hasResult))
    }

    // MARK: - Arm A: default → no "No matches" badge

    func testBar_defaultState_noBadge() throws {
        let view = try bar(query: "", hasResult: true)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"image="magnifyingglass""#), "the search glyph:\n\(tree)")
        XCTAssertTrue(tree.contains(#"kind=editable text="""#),
                      "the query field binds to the (empty) terminalSearchQuery:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Aa""#) && tree.contains(#"text=".*""#) && tree.contains(#"text="Wˌ""#),
                      "the three search-option toggle buttons:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Done""#), "the Done button:\n\(tree)")
        XCTAssertFalse(tree.contains(#"text="No matches""#),
                       "the default state must NOT show the No-matches badge:\n\(tree)")
        try assertViewSnapshot(of: view, named: "TerminalSearchBar.default")
    }

    // MARK: - Arm B: query + no result → "No matches" badge renders

    func testBar_noResultWithQuery_showsBadge() throws {
        let view = try bar(query: "missing", hasResult: false)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"kind=editable text="missing""#),
                      "the query field tracks terminalSearchQuery:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="No matches""#),
                      "the !hasResult && !query.isEmpty arm renders the badge:\n\(tree)")
        try assertViewSnapshot(of: view, named: "TerminalSearchBar.noMatches")
    }

    func testBar_deterministic_byteIdenticalTwice() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try bar(query: "missing", hasResult: false))
        let b = try ViewSnapshotHost.snapshotText(of: try bar(query: "missing", hasResult: false))
        XCTAssertEqual(a, b, "the bar must serialize byte-identically twice")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The "No matches" badge is the data-driven conditional arm: it appears only when
    /// `!hasResult && !query.isEmpty`. The two states must differ.
    func testBar_negativeControl_badgeArmFlips() throws {
        let withBadge = try ViewSnapshotHost.snapshotText(of: try bar(query: "missing", hasResult: false))
        let noBadge = try ViewSnapshotHost.snapshotText(of: try bar(query: "", hasResult: true))
        XCTAssertNotEqual(withBadge, noBadge, "the No-matches arm must flip with the search state")
        XCTAssertTrue(withBadge.contains(#"text="No matches""#))
        XCTAssertFalse(noBadge.contains(#"text="No matches""#))
    }
}
#endif
