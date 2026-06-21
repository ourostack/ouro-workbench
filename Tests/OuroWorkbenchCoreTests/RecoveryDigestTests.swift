import XCTest
@testable import OuroWorkbenchCore

/// U8b: the sidebar Recovery row text, its hover help, the sheet header, the
/// sheet row count, and `shouldShowRecovery` must all derive from ONE shared
/// value and never disagree. `RecoveryDigest` is that value — a pure projection
/// of the planner's `[RecoveryPlan]`.
final class RecoveryDigestTests: XCTestCase {
    private func plan(_ action: RecoveryAction, _ reason: String = "r") -> RecoveryPlan {
        RecoveryPlan(entryId: UUID(), runId: nil, action: action, reason: reason)
    }

    // MARK: actionable set

    func testInertActionsAreNotActionable() {
        let digest = RecoveryDigest(plans: [plan(.noAction), plan(.noAction)])
        XCTAssertEqual(digest.actionableCount, 0)
        XCTAssertFalse(digest.shouldShow)
        XCTAssertTrue(digest.actionableEntryIDs.isEmpty)
    }

    func testReattachIsActionableButLossless() {
        let p = plan(.reattach)
        let digest = RecoveryDigest(plans: [p])
        XCTAssertEqual(digest.actionableCount, 1)
        XCTAssertEqual(digest.losslessReattachCount, 1)
        XCTAssertEqual(digest.needsYouCount, 0)
        XCTAssertEqual(digest.autoRecoverableCount, 0)
        XCTAssertTrue(digest.shouldShow)
        XCTAssertEqual(digest.actionableEntryIDs, [p.entryId])
    }

    func testManualActionNeededCountsAsNeedsYou() {
        let p = plan(.manualActionNeeded)
        let digest = RecoveryDigest(plans: [p])
        XCTAssertEqual(digest.actionableCount, 1)
        XCTAssertEqual(digest.needsYouCount, 1)
        XCTAssertEqual(digest.losslessReattachCount, 0)
        XCTAssertEqual(digest.needsYouEntryIDs, [p.entryId])
    }

    func testAutoResumeAndRespawnCountAsAutoRecoverable() {
        let digest = RecoveryDigest(plans: [plan(.autoResume), plan(.respawn)])
        XCTAssertEqual(digest.actionableCount, 2)
        XCTAssertEqual(digest.autoRecoverableCount, 2)
        XCTAssertEqual(digest.needsYouCount, 0)
        XCTAssertEqual(digest.losslessReattachCount, 0)
    }

    // MARK: needs-action subset (U39 / U42) — actionable minus pure reattach

    /// The shared "needs action after a restart" count: auto-recoverable plus
    /// needs-you, EXCLUDING the lossless `.reattach` survivors (a pure reconnect
    /// needs no action). The drill's one-line status (U39) and the boss-watch
    /// gate (U42) both read this single derivation.
    func testNeedsActionCountExcludesReattach() {
        let digest = RecoveryDigest(plans: [
            plan(.reattach), plan(.reattach),
            plan(.autoResume), plan(.respawn),
            plan(.manualActionNeeded),
            plan(.noAction),
        ])
        // actionableCount counts reattach; needsActionCount does not.
        XCTAssertEqual(digest.actionableCount, 5)
        XCTAssertEqual(digest.needsActionCount, 3)
        XCTAssertTrue(digest.hasNeedsAction)
    }

    /// A reattach-only workspace has nothing that needs action — `hasNeedsAction`
    /// is false even though `actionableCount` is non-zero.
    func testReattachOnlyHasNoNeedsAction() {
        let digest = RecoveryDigest(plans: [plan(.reattach), plan(.reattach)])
        XCTAssertEqual(digest.actionableCount, 2)
        XCTAssertEqual(digest.needsActionCount, 0)
        XCTAssertFalse(digest.hasNeedsAction)
    }

    /// An empty / inert-only workspace has no needs-action.
    func testNoNeedsActionWhenInert() {
        XCTAssertEqual(RecoveryDigest(plans: []).needsActionCount, 0)
        XCTAssertFalse(RecoveryDigest(plans: [plan(.noAction)]).hasNeedsAction)
    }

    // MARK: the contradiction U8b fixes — one count, every surface

    /// A workspace of only live reattaches must NEVER read "0 recovery actions"
    /// over a non-empty list. The single status string counts every actionable
    /// row, including reattaches.
    func testLosslessReattachOnlyWorkspaceNeverReadsZero() {
        let digest = RecoveryDigest(plans: [plan(.reattach), plan(.reattach)])
        XCTAssertEqual(digest.actionableCount, 2)
        XCTAssertTrue(digest.shouldShow)
        // The row/header status must reflect the same 2 rows the sheet lists.
        XCTAssertFalse(digest.statusLine.contains("0 "))
        XCTAssertTrue(digest.statusLine.contains("2"))
    }

    func testStatusLineAndHelpAgreeWithRowCount() {
        let digest = RecoveryDigest(plans: [plan(.reattach), plan(.manualActionNeeded), plan(.autoResume)])
        XCTAssertEqual(digest.actionableCount, 3)
        // The help carries the single total; the breakdown buckets sum to it.
        XCTAssertTrue(digest.helpText.contains("3"))
        XCTAssertEqual(
            digest.losslessReattachCount + digest.autoRecoverableCount + digest.needsYouCount,
            digest.actionableCount
        )
        // The status line and sheet header are the same shared string.
        XCTAssertEqual(digest.statusLine, digest.sheetHeader)
    }

    func testSingularGrammar() {
        let digest = RecoveryDigest(plans: [plan(.reattach)])
        XCTAssertTrue(digest.statusLine.contains("1 session"))
        XCTAssertFalse(digest.statusLine.contains("1 sessions"))
    }

    // MARK: distinct lossless-reattach labelling (never an "alarming" action)

    func testReattachIsLabelledAsNoLoss() {
        let digest = RecoveryDigest(plans: [plan(.reattach)])
        // The status distinguishes a lossless reconnect from an alarming action.
        XCTAssertTrue(digest.statusLine.lowercased().contains("reconnect"))
        XCTAssertFalse(digest.statusLine.lowercased().contains("lost"))
    }

    func testNeedsYouSurfacesInStatusWhenPresent() {
        let digest = RecoveryDigest(plans: [plan(.reattach), plan(.manualActionNeeded)])
        XCTAssertEqual(digest.needsYouCount, 1)
        XCTAssertTrue(digest.statusLine.lowercased().contains("need"))
    }

    func testPluralNeedsYouGrammar() {
        // Two manual-action sessions exercise the plural arm of the "need(s) you"
        // clause (the singular arm is covered by `testNeedsYouSurfacesInStatusWhenPresent`).
        let digest = RecoveryDigest(plans: [plan(.manualActionNeeded), plan(.manualActionNeeded)])
        XCTAssertEqual(digest.needsYouCount, 2)
        XCTAssertTrue(digest.statusLine.contains("2 sessions need you"), "got: \(digest.statusLine)")
    }

    // MARK: bucket entry-id accessors (drive the sheet groups)

    func testReattachAndAutoRecoverableEntryIDsTrackTheirBuckets() {
        let reattach = plan(.reattach)
        let resume = plan(.autoResume)
        let respawn = plan(.respawn)
        let manual = plan(.manualActionNeeded)
        let digest = RecoveryDigest(plans: [reattach, resume, respawn, manual])

        XCTAssertEqual(digest.reattachEntryIDs, [reattach.entryId])
        XCTAssertEqual(digest.autoRecoverableEntryIDs, [resume.entryId, respawn.entryId])
    }

    // MARK: empty

    func testEmptyDigestHidesAndReadsCalm() {
        let digest = RecoveryDigest(plans: [])
        XCTAssertEqual(digest.actionableCount, 0)
        XCTAssertFalse(digest.shouldShow)
        // The empty guards of the two operator-facing strings (#U8b).
        XCTAssertEqual(digest.statusLine, "Nothing to recover")
        XCTAssertEqual(digest.sheetHeader, "Nothing to recover")
        XCTAssertEqual(digest.helpText, "Nothing is waiting on recovery.")
    }
}
