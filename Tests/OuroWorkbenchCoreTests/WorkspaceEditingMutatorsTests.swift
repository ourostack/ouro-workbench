import XCTest
@testable import OuroWorkbenchCore

/// Slice ②d — pure editing mutators on `WorkspaceState`. These back the in-app
/// rename/pin/remove-custom-name affordances: the App mutates `model.state`
/// through these and persists via `save()` (D2d-6/D2d-7). Core is test-visible
/// (`@testable import`), so this is real red→green XCTest TDD; every arm
/// (found-id, unknown-id no-op, nil-vs-value, idempotent-clear, double-toggle)
/// is covered.
final class WorkspaceEditingMutatorsTests: XCTestCase {

    // MARK: - Fixtures

    private func makeEntry(
        id: UUID = UUID(),
        name: String = "tab",
        tabNameOverride: String? = nil
    ) -> ProcessEntry {
        ProcessEntry(
            id: id,
            projectId: UUID(),
            name: name,
            kind: .terminalAgent,
            executable: "claude",
            workingDirectory: "/tmp",
            tabNameOverride: tabNameOverride
        )
    }

    // MARK: - setWorkspaceNameOverride

    func testSetWorkspaceNameOverrideSetsOnMatchingWorkspace() {
        let id = UUID()
        var state = WorkspaceState(workspaces: [Workspace(id: id, autoName: "auto")])
        state.setWorkspaceNameOverride(workspaceId: id, to: "Custom")
        XCTAssertEqual(state.workspaces.first?.nameOverride, "Custom")
        XCTAssertEqual(state.workspaces.first?.effectiveName, "Custom")
    }

    func testSetWorkspaceNameOverrideUnknownIdIsNoOp() {
        let id = UUID()
        let original = WorkspaceState(workspaces: [Workspace(id: id, autoName: "auto")])
        var state = original
        state.setWorkspaceNameOverride(workspaceId: UUID(), to: "Custom")
        XCTAssertEqual(state, original, "an unknown id must leave state untouched")
    }

    func testSetWorkspaceNameOverrideToNilClearsOverride() {
        let id = UUID()
        var state = WorkspaceState(
            workspaces: [Workspace(id: id, autoName: "auto", nameOverride: "Custom")]
        )
        state.setWorkspaceNameOverride(workspaceId: id, to: nil)
        XCTAssertNil(state.workspaces.first?.nameOverride)
        XCTAssertEqual(state.workspaces.first?.effectiveName, "auto")
    }

    func testSetWorkspaceNameOverrideOnlyAffectsMatchingWorkspace() {
        let target = UUID()
        let other = UUID()
        var state = WorkspaceState(workspaces: [
            Workspace(id: target, autoName: "a"),
            Workspace(id: other, autoName: "b"),
        ])
        state.setWorkspaceNameOverride(workspaceId: target, to: "Renamed")
        XCTAssertEqual(state.workspaces.first(where: { $0.id == target })?.nameOverride, "Renamed")
        XCTAssertNil(state.workspaces.first(where: { $0.id == other })?.nameOverride)
    }

    // MARK: - clearWorkspaceNameOverride

    func testClearWorkspaceNameOverrideRevertsToAutoName() {
        let id = UUID()
        var state = WorkspaceState(
            workspaces: [Workspace(id: id, autoName: "auto", nameOverride: "Custom")]
        )
        state.clearWorkspaceNameOverride(workspaceId: id)
        XCTAssertNil(state.workspaces.first?.nameOverride)
        XCTAssertEqual(state.workspaces.first?.effectiveName, "auto")
    }

    func testClearWorkspaceNameOverrideUnknownIdIsNoOp() {
        let id = UUID()
        let original = WorkspaceState(
            workspaces: [Workspace(id: id, autoName: "auto", nameOverride: "Custom")]
        )
        var state = original
        state.clearWorkspaceNameOverride(workspaceId: UUID())
        XCTAssertEqual(state, original, "an unknown id must leave state untouched")
    }

    func testClearWorkspaceNameOverrideAlreadyNilIsIdempotent() {
        let id = UUID()
        let original = WorkspaceState(workspaces: [Workspace(id: id, autoName: "auto")])
        var state = original
        state.clearWorkspaceNameOverride(workspaceId: id)
        XCTAssertNil(state.workspaces.first?.nameOverride)
        XCTAssertEqual(state, original, "clearing an already-nil override is a no-op")
    }

    // MARK: - toggleWorkspacePin

    func testToggleWorkspacePinFlipsFromFalseToTrue() {
        let id = UUID()
        var state = WorkspaceState(workspaces: [Workspace(id: id, autoName: "a", isPinned: false)])
        state.toggleWorkspacePin(workspaceId: id)
        XCTAssertTrue(state.workspaces.first?.isPinned == true)
    }

    func testToggleWorkspacePinFlipsFromTrueToFalse() {
        let id = UUID()
        var state = WorkspaceState(workspaces: [Workspace(id: id, autoName: "a", isPinned: true)])
        state.toggleWorkspacePin(workspaceId: id)
        XCTAssertFalse(state.workspaces.first?.isPinned == true)
    }

    func testToggleWorkspacePinTwiceReturnsToOriginal() {
        let id = UUID()
        let original = WorkspaceState(workspaces: [Workspace(id: id, autoName: "a", isPinned: false)])
        var state = original
        state.toggleWorkspacePin(workspaceId: id)
        state.toggleWorkspacePin(workspaceId: id)
        XCTAssertEqual(state, original, "double-toggle is identity")
    }

    func testToggleWorkspacePinUnknownIdIsNoOp() {
        let id = UUID()
        let original = WorkspaceState(workspaces: [Workspace(id: id, autoName: "a")])
        var state = original
        state.toggleWorkspacePin(workspaceId: UUID())
        XCTAssertEqual(state, original, "an unknown id must leave state untouched")
    }

    // MARK: - setTabNameOverride

    func testSetTabNameOverrideSetsOnMatchingEntry() {
        let id = UUID()
        var state = WorkspaceState(processEntries: [makeEntry(id: id, name: "auto tab")])
        state.setTabNameOverride(tabId: id, to: "Renamed Tab")
        XCTAssertEqual(state.processEntries.first?.tabNameOverride, "Renamed Tab")
        XCTAssertEqual(state.processEntries.first?.effectiveTabName, "Renamed Tab")
    }

    func testSetTabNameOverrideUnknownIdIsNoOp() {
        let id = UUID()
        let original = WorkspaceState(processEntries: [makeEntry(id: id, name: "auto tab")])
        var state = original
        state.setTabNameOverride(tabId: UUID(), to: "Renamed Tab")
        XCTAssertEqual(state, original, "an unknown id must leave state untouched")
    }

    func testSetTabNameOverrideToNilClearsOverride() {
        let id = UUID()
        var state = WorkspaceState(
            processEntries: [makeEntry(id: id, name: "auto tab", tabNameOverride: "Custom")]
        )
        state.setTabNameOverride(tabId: id, to: nil)
        XCTAssertNil(state.processEntries.first?.tabNameOverride)
        XCTAssertEqual(state.processEntries.first?.effectiveTabName, "auto tab")
    }

    func testSetTabNameOverrideOnlyAffectsMatchingEntry() {
        let target = UUID()
        let other = UUID()
        var state = WorkspaceState(processEntries: [
            makeEntry(id: target, name: "a"),
            makeEntry(id: other, name: "b"),
        ])
        state.setTabNameOverride(tabId: target, to: "Renamed")
        XCTAssertEqual(state.processEntries.first(where: { $0.id == target })?.tabNameOverride, "Renamed")
        XCTAssertNil(state.processEntries.first(where: { $0.id == other })?.tabNameOverride)
    }
}
