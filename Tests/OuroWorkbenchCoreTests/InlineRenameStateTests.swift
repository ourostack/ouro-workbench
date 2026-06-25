import XCTest
@testable import OuroWorkbenchCore

/// Slice ②d — pure state for the inline rename editor: which target (if any) is being
/// renamed and the draft text. One state serves BOTH the workspace menu and the tab
/// menu (`.workspace(UUID)` vs `.tab(UUID)`), so the App holds a single
/// `@Published var inlineRename` and the row/tab swaps label↔editor via `isEditing`.
/// Framework-free (no SwiftUI) so it is XCTest-visible and coverage-gated.
final class InlineRenameStateTests: XCTestCase {

    private let wsA = UUID()
    private let wsB = UUID()
    private let tabA = UUID()

    // MARK: - Initial / inactive

    func testInitialStateIsInactive() {
        let state = InlineRenameState()
        XCTAssertNil(state.target)
        XCTAssertFalse(state.isEditing(.workspace(wsA)))
        XCTAssertFalse(state.isEditing(.tab(tabA)))
    }

    // MARK: - begin

    func testBeginActivatesTargetWithPrefilledDraft() {
        var state = InlineRenameState()
        state.begin(target: .workspace(wsA), prefill: "My Workspace")
        XCTAssertEqual(state.target, .workspace(wsA))
        XCTAssertEqual(state.draft, "My Workspace")
        XCTAssertTrue(state.isEditing(.workspace(wsA)))
    }

    func testBeginOnTabActivatesTabTarget() {
        var state = InlineRenameState()
        state.begin(target: .tab(tabA), prefill: "My Tab")
        XCTAssertEqual(state.target, .tab(tabA))
        XCTAssertEqual(state.draft, "My Tab")
        XCTAssertTrue(state.isEditing(.tab(tabA)))
    }

    // MARK: - isEditing discrimination

    func testIsEditingFalseForADifferentTargetWhileActive() {
        var state = InlineRenameState()
        state.begin(target: .workspace(wsA), prefill: "A")
        XCTAssertFalse(state.isEditing(.workspace(wsB)), "a different workspace id is not editing")
        XCTAssertFalse(state.isEditing(.tab(tabA)), "a tab target is not the active workspace target")
    }

    // MARK: - cancel

    func testCancelDeactivatesAndClearsDraft() {
        var state = InlineRenameState()
        state.begin(target: .workspace(wsA), prefill: "Draft text")
        state.cancel()
        XCTAssertNil(state.target)
        XCTAssertEqual(state.draft, "", "cancel clears the draft so no stale text leaks into the next begin")
        XCTAssertFalse(state.isEditing(.workspace(wsA)))
    }

    // MARK: - commit

    func testCommitReturnsActiveTargetAndDraftThenGoesInactive() {
        var state = InlineRenameState()
        state.begin(target: .workspace(wsA), prefill: "Original")
        state.draft = "Edited"
        let pending = state.commit()
        XCTAssertEqual(pending?.target, .workspace(wsA))
        XCTAssertEqual(pending?.input, "Edited")
        XCTAssertNil(state.target, "commit goes inactive")
        XCTAssertEqual(state.draft, "")
        XCTAssertFalse(state.isEditing(.workspace(wsA)))
    }

    func testCommitWhenInactiveReturnsNil() {
        var state = InlineRenameState()
        XCTAssertNil(state.commit(), "committing with no active target returns nil and stays inactive")
        XCTAssertNil(state.target)
    }

    // MARK: - target switch (no stale draft leak)

    func testBeginOnNewTargetWhileActiveSwitchesAndReplacesDraft() {
        var state = InlineRenameState()
        state.begin(target: .workspace(wsA), prefill: "A draft")
        state.draft = "edited A"
        state.begin(target: .tab(tabA), prefill: "Tab prefill")
        XCTAssertEqual(state.target, .tab(tabA))
        XCTAssertEqual(state.draft, "Tab prefill", "switching target replaces the draft — no stale leak")
        XCTAssertFalse(state.isEditing(.workspace(wsA)))
        XCTAssertTrue(state.isEditing(.tab(tabA)))
    }

    // MARK: - target identity

    func testRenameTargetEquatableDiscriminatesKindAndId() {
        XCTAssertEqual(InlineRenameState.Target.workspace(wsA), .workspace(wsA))
        XCTAssertNotEqual(InlineRenameState.Target.workspace(wsA), .workspace(wsB))
        XCTAssertNotEqual(InlineRenameState.Target.workspace(wsA), .tab(wsA),
                          "same UUID but different kind is a different target")
    }
}
