import XCTest
@testable import OuroWorkbenchCore

/// FIX 1 (HIGH, destructive) — the pure decision behind `activeEntry`: which
/// terminal the "selected-session" menu chords (⌘. Stop, ⌘L Redraw, ⌘F Find)
/// act on. The bug: full-screen focus mode (entered from a row's Focus button or
/// `jumpToAttentionPrompt`) sets only `terminalFocusEntryID`, so the chords routed
/// through the sidebar selection / secondary pane and could KILL a *different*
/// agent than the one on screen. Focus mode must authoritatively define the active
/// terminal, so this resolver makes focus-mode WIN over both the secondary pane
/// and the sidebar selection.
final class ActiveEntryResolverTests: XCTestCase {

    private let entryA = UUID()
    private let entryB = UUID()
    private let entryC = UUID()

    // MARK: - Focus mode wins (THE bug)

    func testFocusModeWinsOverSidebarSelection() {
        // Focus on B while A is sidebar-selected → active is B (not A). This is the
        // destructive case: ⌘. must stop the terminal on screen (B), never A.
        let active = ActiveEntryResolver.resolve(
            selectedEntryID: entryA,
            terminalFocusEntryID: entryB,
            focusEntryResolves: true,
            splitIsActive: false,
            secondaryPaneIsFocused: false,
            secondaryPaneEntryID: nil
        )
        XCTAssertEqual(active, entryB)
    }

    func testFocusModeWinsOverFocusedSecondaryPane() {
        // Even with a split whose secondary pane is focused, an active focus mode
        // takes priority — the focus view is what's on screen.
        let active = ActiveEntryResolver.resolve(
            selectedEntryID: entryA,
            terminalFocusEntryID: entryB,
            focusEntryResolves: true,
            splitIsActive: true,
            secondaryPaneIsFocused: true,
            secondaryPaneEntryID: entryC
        )
        XCTAssertEqual(active, entryB)
    }

    func testFocusModeWithNoSidebarSelectionStillTargetsTheFocusedTerminal() {
        // `jumpToAttentionPrompt` can enter focus with the sidebar selection elsewhere
        // / unset; the focused terminal still wins.
        let active = ActiveEntryResolver.resolve(
            selectedEntryID: nil,
            terminalFocusEntryID: entryB,
            focusEntryResolves: true,
            splitIsActive: false,
            secondaryPaneIsFocused: false,
            secondaryPaneEntryID: nil
        )
        XCTAssertEqual(active, entryB)
    }

    // MARK: - Focus id present but the session no longer resolves

    func testStaleFocusIdThatNoLongerResolvesFallsBackToSelection() {
        // `terminalFocusEntry` returns nil when the focused session died; the
        // resolver must NOT target a dead/stale focus id — it falls back to the
        // normal (non-focus) decision so the chords still hit a live target.
        let active = ActiveEntryResolver.resolve(
            selectedEntryID: entryA,
            terminalFocusEntryID: entryB,
            focusEntryResolves: false,
            splitIsActive: false,
            secondaryPaneIsFocused: false,
            secondaryPaneEntryID: nil
        )
        XCTAssertEqual(active, entryA)
    }

    // MARK: - Inverse-bug guard: focus OFF preserves the pre-fix behavior exactly

    func testFocusOffWithNoSplitTargetsSidebarSelection() {
        let active = ActiveEntryResolver.resolve(
            selectedEntryID: entryA,
            terminalFocusEntryID: nil,
            focusEntryResolves: false,
            splitIsActive: false,
            secondaryPaneIsFocused: false,
            secondaryPaneEntryID: nil
        )
        XCTAssertEqual(active, entryA)
    }

    func testFocusOffWithFocusedSecondaryPaneTargetsTheSecondaryEntry() {
        // The pre-fix split behavior: secondary pane focused → its entry is active.
        let active = ActiveEntryResolver.resolve(
            selectedEntryID: entryA,
            terminalFocusEntryID: nil,
            focusEntryResolves: false,
            splitIsActive: true,
            secondaryPaneIsFocused: true,
            secondaryPaneEntryID: entryC
        )
        XCTAssertEqual(active, entryC)
    }

    func testFocusOffWithPrimaryPaneFocusedTargetsSidebarSelection() {
        // Split active but primary pane focused → sidebar selection, as before.
        let active = ActiveEntryResolver.resolve(
            selectedEntryID: entryA,
            terminalFocusEntryID: nil,
            focusEntryResolves: false,
            splitIsActive: true,
            secondaryPaneIsFocused: false,
            secondaryPaneEntryID: entryC
        )
        XCTAssertEqual(active, entryA)
    }

    func testFocusOffSecondaryFocusedButSecondaryEntryUnresolvedFallsBackToSelection() {
        // Secondary pane focused but its session no longer resolves (picker / dead
        // session) → fall back to the sidebar selection, matching `secondaryPaneEntry == nil`.
        let active = ActiveEntryResolver.resolve(
            selectedEntryID: entryA,
            terminalFocusEntryID: nil,
            focusEntryResolves: false,
            splitIsActive: true,
            secondaryPaneIsFocused: true,
            secondaryPaneEntryID: nil
        )
        XCTAssertEqual(active, entryA)
    }

    func testNothingSelectedAndNoFocusReturnsNil() {
        // No selection, no focus, no split → no active entry id.
        let active = ActiveEntryResolver.resolve(
            selectedEntryID: nil,
            terminalFocusEntryID: nil,
            focusEntryResolves: false,
            splitIsActive: false,
            secondaryPaneIsFocused: false,
            secondaryPaneEntryID: nil
        )
        XCTAssertNil(active)
    }
}
