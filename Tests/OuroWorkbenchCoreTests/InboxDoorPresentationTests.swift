import XCTest
@testable import OuroWorkbenchCore

/// U22: the open-inbox "door" — the tappable "N waiting on you →" affordance the
/// boss pane shows when openInbox > 0, and the calm/absent state when it's zero.
/// This pure presentation derives the label and the top-group severity so the
/// boss-pane pill, the tappable "inbox" chip, and the collapsed-pane count badge
/// all agree, and so a zero-count case can never render a dead button.
final class InboxDoorPresentationTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func decision(_ kind: BossDecisionKind, prompt: String = "Proceed? (y/N)") -> BossInboxDecision {
        BossInboxDecision(source: "boss:slugger", prompt: prompt, kind: kind, reasoning: "because")
    }

    func testZeroInboxIsAbsentSoNoDeadButton() {
        var state = WorkspaceState()
        // An applied auto-advance is audit-only — not in the open inbox.
        var d = decision(.autoAdvance)
        d.status = .applied
        state.recordDecision(d)
        let door = InboxDoorPresentation.resolve(state: state, now: now)
        XCTAssertNil(door, "zero open items → no door at all")
    }

    func testEmptyLogIsAbsent() {
        XCTAssertNil(InboxDoorPresentation.resolve(state: WorkspaceState(), now: now))
    }

    func testSingleWaitingItemReadsSingular() {
        var state = WorkspaceState()
        state.recordDecision(decision(.escalate))
        let door = InboxDoorPresentation.resolve(state: state, now: now)
        XCTAssertEqual(door?.count, 1)
        XCTAssertEqual(door?.label, "1 waiting on you")
    }

    func testMultipleWaitingItemsReadPlural() {
        var state = WorkspaceState()
        state.recordDecision(decision(.escalate, prompt: "a"))
        state.recordDecision(decision(.hold, prompt: "b"))
        let door = InboxDoorPresentation.resolve(state: state, now: now)
        XCTAssertEqual(door?.count, 2)
        XCTAssertEqual(door?.label, "2 waiting on you")
    }

    func testSeverityReflectsTopGroup() {
        var state = WorkspaceState()
        // A hold (low) plus an escalate (elevated) → the door tints to the top
        // severity in the queue.
        state.recordDecision(decision(.hold, prompt: "park"))
        state.recordDecision(decision(.escalate, prompt: "need you"))
        let door = InboxDoorPresentation.resolve(state: state, now: now)
        XCTAssertEqual(door?.topSeverity, .elevated)
    }

    func testCriticalPromptElevatesTopSeverity() {
        var state = WorkspaceState()
        // A destructive/secret prompt floors to critical regardless of kind.
        state.recordDecision(decision(.escalate, prompt: "rm -rf / — confirm? (y/N)"))
        let door = InboxDoorPresentation.resolve(state: state, now: now)
        XCTAssertEqual(door?.topSeverity, .critical)
    }

    func testAccessibilityLabelNamesTheCountAndDestination() {
        var state = WorkspaceState()
        state.recordDecision(decision(.escalate))
        let door = InboxDoorPresentation.resolve(state: state, now: now)
        XCTAssertEqual(door?.accessibilityLabel, "1 decision waiting on you — open the Decision Inbox")
    }

    func testAccessibilityLabelPluralizesForMultiple() {
        var state = WorkspaceState()
        state.recordDecision(decision(.escalate, prompt: "a"))
        state.recordDecision(decision(.hold, prompt: "b"))
        let door = InboxDoorPresentation.resolve(state: state, now: now)
        XCTAssertEqual(door?.accessibilityLabel, "2 decisions waiting on you — open the Decision Inbox")
    }

    func testBadgeTextMirrorsCount() {
        var state = WorkspaceState()
        state.recordDecision(decision(.escalate, prompt: "a"))
        state.recordDecision(decision(.hold, prompt: "b"))
        state.recordDecision(decision(.escalate, prompt: "c"))
        XCTAssertEqual(InboxDoorPresentation.resolve(state: state, now: now)?.badgeText, "3")
    }

    func testHelpInvitesTheClick() {
        var state = WorkspaceState()
        state.recordDecision(decision(.escalate))
        let door = InboxDoorPresentation.resolve(state: state, now: now)
        XCTAssertEqual(door?.help, "Open the Decision Inbox to see and triage what the boss escalated.")
    }
}
