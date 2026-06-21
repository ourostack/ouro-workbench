import XCTest
@testable import OuroWorkbenchCore

/// U10: the live session-detail header must tell the truth about attention.
/// This pins the pure mapping the header + banner drive from — color/icon/label
/// for the dot, and the slim "why" banner above the terminal — so the operator
/// sees at a glance that THIS session needs them and the boss's waiting signal
/// (read from the same `attention`) stays consistent with what the header shows.
final class SessionDetailAttentionPresentationTests: XCTestCase {
    private func resolve(
        attention: AttentionState,
        isActiveSession: Bool,
        canRecover: Bool = false,
        isArchived: Bool = false,
        reason: String? = nil
    ) -> SessionDetailAttentionPresentation.Presentation {
        SessionDetailAttentionPresentation.resolve(
            attention: attention,
            isActiveSession: isActiveSession,
            canRecover: canRecover,
            isArchived: isArchived,
            reason: reason
        )
    }

    // MARK: - Header dot: an active session's dot follows its real attention

    func testActiveWaitingShowsAttentionDotNotGreen() {
        let p = resolve(attention: .waitingOnHuman, isActiveSession: true, reason: "Proceed? (y/N)")
        // The dot is keyed to the attention itself — the App maps this through the
        // shared AttentionState.healthColor/healthSymbol/healthLabel (orange/hand).
        XCTAssertEqual(p.dot, .attention(.waitingOnHuman))
    }

    func testActiveBlockedShowsBlockedDot() {
        let p = resolve(attention: .blocked, isActiveSession: true, reason: "build failed")
        XCTAssertEqual(p.dot, .attention(.blocked))
    }

    func testActiveNeedsBossReviewShowsReviewDot() {
        let p = resolve(attention: .needsBossReview, isActiveSession: true)
        XCTAssertEqual(p.dot, .attention(.needsBossReview))
    }

    func testActiveRunningShowsActiveDot() {
        let p = resolve(attention: .active, isActiveSession: true)
        XCTAssertEqual(p.dot, .attention(.active))
    }

    // MARK: - Header dot: inactive keeps grey/orange recovery semantics

    func testArchivedShowsDimmedDot() {
        let p = resolve(attention: .waitingOnHuman, isActiveSession: false, isArchived: true)
        // Archived wins over everything — never alarms.
        XCTAssertEqual(p.dot, .archived)
    }

    func testInactiveRecoverableShowsRecoveryDot() {
        // A stopped-but-recoverable session keeps the orange recovery dot, not an
        // attention color (its process isn't live).
        let p = resolve(attention: .waitingOnHuman, isActiveSession: false, canRecover: true)
        XCTAssertEqual(p.dot, .recoverable)
    }

    func testInactiveNotRecoverableShowsIdleDot() {
        let p = resolve(attention: .idle, isActiveSession: false, canRecover: false)
        XCTAssertEqual(p.dot, .inactive)
    }

    // MARK: - Banner: shows only when an active session needs the human

    func testActiveWaitingRendersWaitingBanner() {
        let p = resolve(attention: .waitingOnHuman, isActiveSession: true, reason: "Proceed with deploy? (y/N)")
        let banner = try? XCTUnwrap(p.banner)
        XCTAssertEqual(banner?.kind, .waitingOnHuman)
        XCTAssertEqual(banner?.text, "Waiting on you · Proceed with deploy? (y/N)")
        XCTAssertTrue(banner?.offersJumpToPrompt ?? false)
    }

    func testActiveBlockedRendersBlockedBanner() {
        let p = resolve(attention: .blocked, isActiveSession: true, reason: "Build failed after 3.2s")
        let banner = try? XCTUnwrap(p.banner)
        XCTAssertEqual(banner?.kind, .blocked)
        XCTAssertEqual(banner?.text, "Blocked · Build failed after 3.2s")
        XCTAssertTrue(banner?.offersJumpToPrompt ?? false)
    }

    func testWaitingBannerWithoutAReasonStillReadsCleanly() {
        // No detected reason → a bare, non-empty headline (never "Waiting on you · ").
        let p = resolve(attention: .waitingOnHuman, isActiveSession: true, reason: nil)
        XCTAssertEqual(p.banner?.text, "Waiting on you")
    }

    func testBlankReasonIsTreatedAsNoReason() {
        let p = resolve(attention: .waitingOnHuman, isActiveSession: true, reason: "   ")
        XCTAssertEqual(p.banner?.text, "Waiting on you")
    }

    func testNeedsBossReviewRendersReviewBannerWithoutJump() {
        // The boss flagged this; there's no operator prompt to jump to.
        let p = resolve(attention: .needsBossReview, isActiveSession: true, reason: nil)
        let banner = try? XCTUnwrap(p.banner)
        XCTAssertEqual(banner?.kind, .needsBossReview)
        XCTAssertEqual(banner?.text, "Needs boss review")
        XCTAssertFalse(banner?.offersJumpToPrompt ?? true)
    }

    // MARK: - Banner: NEVER shows for active/idle, or for inactive sessions

    func testActiveRunningHasNoBanner() {
        XCTAssertNil(resolve(attention: .active, isActiveSession: true).banner)
    }

    func testIdleHasNoBanner() {
        XCTAssertNil(resolve(attention: .idle, isActiveSession: true).banner)
    }

    func testInactiveWaitingHasNoBanner() {
        // No live process → nothing for the operator to answer at the prompt; the
        // recovery surface owns this case. The banner is for LIVE attention only.
        XCTAssertNil(resolve(attention: .waitingOnHuman, isActiveSession: false, canRecover: true).banner)
    }

    func testArchivedHasNoBanner() {
        XCTAssertNil(resolve(attention: .blocked, isActiveSession: false, isArchived: true).banner)
    }
}
