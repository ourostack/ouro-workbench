import XCTest
@testable import OuroWorkbenchCore

/// Durable wiring assertions for Slice 8c (boss-forward UI). These read the App
/// source directly — the App target isn't coverage-gated and can't be
/// click-tested in CI, so we pin the structural wiring instead: the session
/// STATUS list fronts the boss dashboard, is driven by Core's `SessionStatusList`
/// (no view-side classification), a row click reuses the existing session
/// selection, and — critically — the change is ADDITIVE: the terminal sidebar
/// stays present and reachable.
final class BossForwardStatusWiringTests: XCTestCase {
    func testStatusListViewIsWiredIntoBossDashboard() throws {
        let source = try appSource()

        // The view exists and is rendered inside the boss dashboard's body,
        // before the conversation (boss-forward: status at a glance first).
        XCTAssertTrue(source.contains("struct SessionStatusListView: View"))
        let dashboard = try sourceSlice(
            in: source,
            from: "private var scrollBody: some View {",
            to: "BossConversationView(model: model)"
        )
        XCTAssertTrue(
            dashboard.contains("SessionStatusListView(model: model)"),
            "The status list must be rendered in the boss dashboard ahead of the conversation"
        )
    }

    func testStatusListClassificationLivesInCoreNotTheView() throws {
        let source = try appSource()
        let view = try sourceSlice(
            in: source,
            from: "struct SessionStatusListView: View",
            to: "private struct SessionStatusBucketSection: View"
        )

        // All bucket classification comes from Core's pure projection; the view
        // never re-derives buckets from attention/run-status itself.
        XCTAssertTrue(view.contains("SessionStatusList.make(from: model.state)"))
        XCTAssertFalse(view.contains(".needsHuman"))
        XCTAssertFalse(view.contains("ProcessStatus"))
    }

    func testStatusRowReusesExistingSessionSelection() throws {
        let source = try appSource()
        let row = try sourceSlice(
            in: source,
            from: "private struct SessionStatusRowView: View",
            to: "struct ActionLogView: View"
        )

        // Clicking a status row reuses the existing cross-group selection path —
        // no new selection plumbing, and the detail pane (hence the terminal)
        // is one click away exactly as before.
        XCTAssertTrue(row.contains("model.selectEntryAcrossGroups(row.id)"))
    }

    func testTerminalSidebarRemainsReachable() throws {
        let source = try appSource()

        // ADDITIVE guarantee: the terminal sidebar is still mounted in the root
        // split view, so every terminal stays reachable the canonical way. The
        // status list is layered on top, not a replacement.
        XCTAssertTrue(source.contains("struct WorkbenchSidebarView: View"))
        let root = try sourceSlice(
            in: source,
            from: "NavigationSplitView(columnVisibility: $columnVisibility) {",
            to: "} detail: {"
        )
        XCTAssertTrue(
            root.contains("WorkbenchSidebarView(model: model)"),
            "The terminal sidebar must remain mounted so terminals stay reachable"
        )
    }

    func testStatusListSurfacesAllThreeBuckets() throws {
        let source = try appSource()
        let view = try sourceSlice(
            in: source,
            from: "struct SessionStatusListView: View",
            to: "private struct SessionStatusBucketSection: View"
        )

        XCTAssertTrue(view.contains("rows: list.waitingOnYou"))
        XCTAssertTrue(view.contains("rows: list.running"))
        XCTAssertTrue(view.contains("rows: list.done"))
    }

    // MARK: - Helpers (mirror WorkbenchSurfacePolicyTests)

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

    private func sourceSlice(in source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let end = try XCTUnwrap(source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound)
        return String(source[start..<end])
    }
}
