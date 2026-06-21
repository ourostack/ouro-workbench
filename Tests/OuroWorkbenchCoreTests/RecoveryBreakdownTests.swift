import XCTest
@testable import OuroWorkbenchCore

/// #U28: the boss-facing recovery scalars must split by HOW the boss may act —
/// reattach (lossless, safe to self-trigger) / resume / respawn (side-effectful
/// self-trigger) / needs_human (the boss literally cannot recover) — derived from
/// the SAME RecoveryDigest/plan source the operator surfaces use, so they can't
/// disagree. `RecoveryBreakdown` is that pure derivation.
final class RecoveryBreakdownTests: XCTestCase {
    private func plan(_ action: RecoveryAction, _ reason: String = "r") -> RecoveryPlan {
        RecoveryPlan(entryId: UUID(), runId: nil, action: action, reason: reason)
    }

    func testEachBucketCountedCorrectly() {
        let breakdown = RecoveryBreakdown(plans: [
            plan(.reattach), plan(.reattach),
            plan(.autoResume),
            plan(.respawn), plan(.respawn), plan(.respawn),
            plan(.manualActionNeeded),
            plan(.noAction) // inert — never counted
        ])
        XCTAssertEqual(breakdown.reattach, 2)
        XCTAssertEqual(breakdown.resume, 1)
        XCTAssertEqual(breakdown.respawn, 3)
        XCTAssertEqual(breakdown.needsHuman, 1)
    }

    func testSumsMatchTheDigestTotal() {
        let plans = [plan(.reattach), plan(.autoResume), plan(.respawn), plan(.manualActionNeeded), plan(.noAction)]
        let breakdown = RecoveryBreakdown(plans: plans)
        let digest = RecoveryDigest(plans: plans)
        // The 4 buckets sum to the digest's actionable total (noAction excluded).
        XCTAssertEqual(breakdown.reattach + breakdown.resume + breakdown.respawn + breakdown.needsHuman, digest.actionableCount)
        XCTAssertEqual(breakdown.total, digest.actionableCount)
        XCTAssertEqual(breakdown.total, 4)
    }

    func testBossActionableExcludesNeedsHuman() {
        let breakdown = RecoveryBreakdown(plans: [plan(.reattach), plan(.autoResume), plan(.respawn), plan(.manualActionNeeded)])
        // The boss may self-trigger reattach/resume/respawn; needs_human is not
        // boss-actionable (it inflated the old raw 'recoverable=N').
        XCTAssertEqual(breakdown.bossActionable, 3)
        XCTAssertEqual(breakdown.bossActionable, breakdown.reattach + breakdown.resume + breakdown.respawn)
    }

    func testReattachOnlyNeverReadsAsNeedsHuman() {
        let breakdown = RecoveryBreakdown(plans: [plan(.reattach), plan(.reattach)])
        XCTAssertEqual(breakdown.reattach, 2)
        XCTAssertEqual(breakdown.needsHuman, 0)
        XCTAssertEqual(breakdown.bossActionable, 2)
    }

    func testEmptyWhenNothingActionable() {
        let breakdown = RecoveryBreakdown(plans: [plan(.noAction)])
        XCTAssertEqual(breakdown.total, 0)
        XCTAssertEqual(breakdown.bossActionable, 0)
        XCTAssertEqual(breakdown.reattach, 0)
        XCTAssertEqual(breakdown.resume, 0)
        XCTAssertEqual(breakdown.respawn, 0)
        XCTAssertEqual(breakdown.needsHuman, 0)
    }

    func testTextScalarBreaksOutEachClass() {
        // The boss reads `reattach=N auto_resume=N respawn=N needs_human=N` so it
        // knows which it may self-execute vs escalate.
        let breakdown = RecoveryBreakdown(plans: [plan(.reattach), plan(.autoResume), plan(.respawn), plan(.manualActionNeeded)])
        XCTAssertEqual(breakdown.scalarText, "reattach=1 auto_resume=1 respawn=1 needs_human=1")
    }

    func testClassForActionMapsEveryAction() {
        // Every RecoveryAction maps to a boss-relayable class string (or nil for
        // the inert noAction), so the action log can record the classification.
        XCTAssertEqual(RecoveryBreakdown.bossActionClass(for: .reattach), "reattach")
        XCTAssertEqual(RecoveryBreakdown.bossActionClass(for: .autoResume), "auto_resume")
        XCTAssertEqual(RecoveryBreakdown.bossActionClass(for: .respawn), "respawn")
        XCTAssertEqual(RecoveryBreakdown.bossActionClass(for: .manualActionNeeded), "needs_human")
        XCTAssertNil(RecoveryBreakdown.bossActionClass(for: .noAction))
    }
}
