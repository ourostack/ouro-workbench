import Foundation
import XCTest
@testable import OuroWorkbenchCore

/// W5 increment 2 — the persisted detail-split shape and its graceful-restore
/// resolver. Mirrors the additive-field back-compat tests for `ProcessEntry`
/// (`ProcessEntryPinTests`): a new optional field must round-trip and, crucially,
/// OLD state files that lack the key must still decode (`detailLayout == nil`)
/// with no `schemaVersion` bump.
final class PaneLayoutStateTests: XCTestCase {
    // MARK: PaneLayoutState Codable round-trip

    func testPaneLayoutStateRoundTrips() throws {
        let secondary = UUID()
        let layout = PaneLayoutState(
            axis: .horizontal,
            secondaryEntryID: secondary,
            activePane: .secondary
        )
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(PaneLayoutState.self, from: data)
        XCTAssertEqual(decoded, layout)
        XCTAssertEqual(decoded.axis, .horizontal)
        XCTAssertEqual(decoded.secondaryEntryID, secondary)
        XCTAssertEqual(decoded.activePane, .secondary)
    }

    func testPaneLayoutStateRoundTripsWithEmptySecondary() throws {
        // An unassigned secondary pane (empty picker) persists as nil.
        let layout = PaneLayoutState(axis: .vertical, secondaryEntryID: nil, activePane: .primary)
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(PaneLayoutState.self, from: data)
        XCTAssertEqual(decoded, layout)
        XCTAssertNil(decoded.secondaryEntryID)
    }

    func testPaneLayoutAxisAndFocusDecodeUnknownLeniently() throws {
        // Forward schema drift (a future axis/focus value) decodes to the safe
        // default rather than throwing and dropping the whole layout — matches
        // every other persisted enum in WorkspaceModels.
        let json = """
        { "axis": "diagonal", "activePane": "tertiary" }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PaneLayoutState.self, from: json)
        XCTAssertEqual(decoded.axis, .vertical)
        XCTAssertEqual(decoded.activePane, .primary)
        XCTAssertNil(decoded.secondaryEntryID)
    }

    // MARK: WorkspaceState back-compat (the load-bearing case)

    func testWorkspaceStateDecodesOldJSONWithoutDetailLayoutKey() throws {
        // Pre-increment-2 state files have no `detailLayout` key. They MUST
        // decode with `detailLayout == nil` (classic single pane) at
        // schemaVersion 1 — no bump, no quarantine.
        let olderJSON = """
        {
            "schemaVersion": 1,
            "boss": { "agentName": "slugger", "scope": "machine" },
            "bossWatchEnabled": true,
            "bossPaneCollapsed": true,
            "projects": [],
            "processEntries": [],
            "processRuns": [],
            "actionLog": [],
            "decisionLog": [],
            "updatedAt": "2026-06-02T00:00:00Z"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(WorkspaceState.self, from: olderJSON)
        XCTAssertEqual(state.schemaVersion, 1)
        XCTAssertNil(state.detailLayout)
    }

    func testWorkspaceStateRoundTripsWithDetailLayout() throws {
        // New state with a split round-trips through the store's JSON config.
        let secondary = UUID()
        let state = WorkspaceState(
            detailLayout: PaneLayoutState(
                axis: .vertical,
                secondaryEntryID: secondary,
                activePane: .secondary
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(state)
        let decoded = try decoder.decode(WorkspaceState.self, from: data)
        XCTAssertEqual(decoded.detailLayout?.axis, .vertical)
        XCTAssertEqual(decoded.detailLayout?.secondaryEntryID, secondary)
        XCTAssertEqual(decoded.detailLayout?.activePane, .secondary)
    }

    func testWorkspaceStateRoundTripsThroughStoreWithDetailLayout() throws {
        // End-to-end through WorkbenchStore (the real save/load path).
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = WorkbenchStore(stateURL: root.appendingPathComponent("workspace.json"))
        let secondary = UUID()
        let state = WorkspaceState(
            detailLayout: PaneLayoutState(
                axis: .horizontal,
                secondaryEntryID: secondary,
                activePane: .primary
            )
        )
        try store.save(state)
        let loaded = try store.load()
        XCTAssertEqual(loaded.detailLayout?.axis, .horizontal)
        XCTAssertEqual(loaded.detailLayout?.secondaryEntryID, secondary)
        XCTAssertEqual(loaded.detailLayout?.activePane, .primary)
        try? FileManager.default.removeItem(at: root)
    }

    func testWorkspaceStateRoundTripsWithNilDetailLayout() throws {
        // The default (single-pane) state encodes detailLayout as nil and
        // decodes back to nil — no spurious split appears on relaunch.
        let state = WorkspaceState()
        XCTAssertNil(state.detailLayout)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorkspaceState.self, from: try encoder.encode(state))
        XCTAssertNil(decoded.detailLayout)
    }

    // MARK: resolved(...) — graceful restore against current entries

    func testResolvedPreservesValidSecondary() {
        let primary = UUID()
        let secondary = UUID()
        let layout = PaneLayoutState(axis: .vertical, secondaryEntryID: secondary, activePane: .secondary)
        let resolved = layout.resolved(
            selectedEntryId: primary,
            liveEntryIDs: [primary, secondary]
        )
        XCTAssertEqual(resolved.secondaryEntryID, secondary, "a live, distinct secondary is preserved")
        XCTAssertEqual(resolved.axis, .vertical)
        XCTAssertEqual(resolved.activePane, .secondary)
    }

    func testResolvedDropsMissingSecondary() {
        let primary = UUID()
        let goneSecondary = UUID()
        let layout = PaneLayoutState(axis: .horizontal, secondaryEntryID: goneSecondary, activePane: .primary)
        let resolved = layout.resolved(
            selectedEntryId: primary,
            liveEntryIDs: [primary] // goneSecondary no longer exists / archived
        )
        XCTAssertNil(resolved.secondaryEntryID, "a missing/archived secondary degrades to an empty picker")
        XCTAssertEqual(resolved.axis, .horizontal, "the split (and its axis) is preserved")
    }

    func testResolvedDropsSecondaryCollidingWithPrimary() {
        // One-session-per-pane: a secondary equal to the restored primary
        // selection must be dropped (the same NSView can't mount twice).
        let shared = UUID()
        let layout = PaneLayoutState(axis: .vertical, secondaryEntryID: shared, activePane: .secondary)
        let resolved = layout.resolved(
            selectedEntryId: shared,
            liveEntryIDs: [shared]
        )
        XCTAssertNil(resolved.secondaryEntryID, "secondary == primary collapses to an empty picker")
    }

    func testResolvedFallsBackFocusWhenSecondaryDropped() {
        // If focus was on a secondary that just lost its session, focus falls
        // back to the always-valid primary.
        let primary = UUID()
        let goneSecondary = UUID()
        let layout = PaneLayoutState(axis: .vertical, secondaryEntryID: goneSecondary, activePane: .secondary)
        let resolved = layout.resolved(
            selectedEntryId: primary,
            liveEntryIDs: [primary]
        )
        XCTAssertNil(resolved.secondaryEntryID)
        XCTAssertEqual(resolved.activePane, .primary, "focus falls back to primary when the secondary is gone")
    }

    func testResolvedKeepsSecondaryFocusWhenSecondaryValid() {
        let primary = UUID()
        let secondary = UUID()
        let layout = PaneLayoutState(axis: .vertical, secondaryEntryID: secondary, activePane: .secondary)
        let resolved = layout.resolved(
            selectedEntryId: primary,
            liveEntryIDs: [primary, secondary]
        )
        XCTAssertEqual(resolved.activePane, .secondary, "secondary focus is kept while the secondary is live")
    }

    func testResolvedKeepsEmptySecondaryPickerSplit() {
        // A split saved with no secondary (empty picker) restores as a split
        // with an empty picker — the operator's two-up layout is preserved.
        let primary = UUID()
        let layout = PaneLayoutState(axis: .horizontal, secondaryEntryID: nil, activePane: .primary)
        let resolved = layout.resolved(
            selectedEntryId: primary,
            liveEntryIDs: [primary]
        )
        XCTAssertNil(resolved.secondaryEntryID)
        XCTAssertEqual(resolved.axis, .horizontal)
        XCTAssertEqual(resolved.activePane, .primary)
    }
}
