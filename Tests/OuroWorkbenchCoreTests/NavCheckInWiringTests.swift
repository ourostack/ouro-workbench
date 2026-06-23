import XCTest
@testable import OuroWorkbenchCore

/// Durable wiring assertions for the nav + check-in batch (FIX 1–4). The App
/// target isn't coverage-gated and can't be click-tested in CI, so — exactly like
/// the other `*WiringTests` — we source-pin the structural wiring that connects
/// each pure Core seam to its App consumer. The pure decisions themselves are
/// exhaustively unit-tested in their own suites (`ActiveEntryResolverTests`,
/// `BossCheckInFailureCopyTests`, `CheckInAvailabilityTests`); these tests pin
/// that the App actually ROUTES through them and branches the way the seam says.
final class NavCheckInWiringTests: XCTestCase {

    // MARK: - FIX 1: focusTerminal / activeEntry honors focus mode

    /// `activeEntry` (what ⌘. Stop / ⌘L Redraw act on) must fold its decision
    /// through the pure `ActiveEntryResolver` seam, NOT inline the old
    /// secondary-pane-or-selection branch that ignored focus mode.
    func testActiveEntryRoutesThroughTheResolverSeam() throws {
        let body = try activeEntryBranch()
        XCTAssertTrue(
            body.contains("ActiveEntryResolver.resolve"),
            "activeEntry must fold its decision through ActiveEntryResolver.resolve"
        )
    }

    /// THE destructive bug: focus mode must feed the resolver so a focused terminal
    /// authoritatively defines the active target. The resolver call must pass both
    /// `terminalFocusEntryID` and a `focusEntryResolves` liveness flag.
    func testActiveEntryFeedsFocusModeIntoTheResolver() throws {
        let body = try activeEntryBranch()
        XCTAssertTrue(
            body.contains("terminalFocusEntryID: terminalFocusEntryID"),
            "the resolver call must pass terminalFocusEntryID so focus mode can win"
        )
        XCTAssertTrue(
            body.contains("focusEntryResolves: terminalFocusEntry != nil"),
            "the resolver call must pass a liveness flag so a stale/dead focus id can't redirect ⌘."
        )
    }

    /// The pre-fix inputs (sidebar selection + the focused-secondary-pane split
    /// state) must still feed the resolver so focus-OFF behavior is unchanged.
    func testActiveEntryStillFeedsSelectionAndSecondaryPane() throws {
        let body = try activeEntryBranch()
        XCTAssertTrue(
            body.contains("selectedEntryID: selectedEntry?.id"),
            "the resolver must still receive the sidebar selection (focus-OFF fallback)"
        )
        XCTAssertTrue(
            body.contains("secondaryPaneIsFocused: activePaneID == .secondary"),
            "the resolver must still receive the focused-secondary-pane state (pre-fix split behavior)"
        )
        XCTAssertTrue(
            body.contains("secondaryPaneEntryID: secondaryPaneEntry?.id"),
            "the resolver must still receive the secondary pane's entry id"
        )
    }

    /// The menu chords route through `activeEntry`, so pinning that the chord
    /// dispatch reads `activeEntry` (not the raw `selectedEntry`) keeps the fix
    /// wired end-to-end: ⌘. / ⌘L hit the focus-mode-aware target.
    func testStopAndRedrawChordsTargetActiveEntry() throws {
        let source = try appSource()
        XCTAssertTrue(
            source.contains("if let entry = model.activeEntry { model.requestStop(entry) }"),
            "the ⌘. Stop chord must target model.activeEntry (focus-mode aware)"
        )
        XCTAssertTrue(
            source.contains("if let entry = model.activeEntry { model.redrawTerminal(entry) }"),
            "the ⌘L Redraw chord must target model.activeEntry (focus-mode aware)"
        )
    }

    // MARK: - Slice helpers

    private func activeEntryBranch() throws -> String {
        let source = try appSource()
        return try sourceSlice(
            in: source,
            from: "var activeEntry: ProcessEntry? {",
            to: "\n    var summary: WorkspaceSummary {"
        )
    }

    // MARK: - Helpers (mirror the other *WiringTests)

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
