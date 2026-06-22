import XCTest
@testable import OuroWorkbenchCore

/// F12a Gap 3b — the un-triaged-waiting reconciler. A waiting-on-human session that
/// the boss emitted NO decision for (empty decisions block, or a decision whose
/// `entryId` couldn't be resolved) never enters the inbox, so it falls out of
/// triage silently. `untriagedWaitingEntryIds` finds those entries so the App can
/// synthesize an escalate decision for each.
final class WaitingSessionReconcilerTests: XCTestCase {
    private func entry(_ name: String, attention: AttentionState, archived: Bool = false) -> ProcessEntry {
        ProcessEntry(
            projectId: UUID(),
            name: name,
            kind: .terminalAgent,
            executable: "agent",
            workingDirectory: "/tmp",
            isArchived: archived,
            attention: attention
        )
    }

    private func openDecision(entryId: UUID?) -> BossInboxDecision {
        BossInboxDecision(
            source: "boss",
            entryId: entryId,
            prompt: "p",
            kind: .escalate,
            reasoning: "r"
        )
    }

    func testWaitingSessionWithNoCoveringInboxIsReturned() {
        let waiting = entry("Waiting", attention: .waitingOnHuman)
        let ids = WaitingSessionReconciler.untriagedWaitingEntryIds(
            entries: [waiting],
            openInbox: []
        )
        XCTAssertEqual(ids, [waiting.id])
    }

    func testWaitingSessionCoveredByAnOpenInboxDecisionIsExcluded() {
        let waiting = entry("Waiting", attention: .waitingOnHuman)
        let ids = WaitingSessionReconciler.untriagedWaitingEntryIds(
            entries: [waiting],
            openInbox: [openDecision(entryId: waiting.id)]
        )
        XCTAssertTrue(ids.isEmpty, "an entry already in the open inbox is triaged — not returned")
    }

    func testNonWaitingSessionsAreExcluded() {
        let idle = entry("Idle", attention: .idle)
        let active = entry("Active", attention: .active)
        let review = entry("Review", attention: .needsBossReview)
        let ids = WaitingSessionReconciler.untriagedWaitingEntryIds(
            entries: [idle, active, review],
            openInbox: []
        )
        XCTAssertTrue(ids.isEmpty, "only .waitingOnHuman sessions need synthesized triage")
    }

    func testArchivedWaitingSessionsAreExcluded() {
        let archived = entry("Archived", attention: .waitingOnHuman, archived: true)
        let ids = WaitingSessionReconciler.untriagedWaitingEntryIds(
            entries: [archived],
            openInbox: []
        )
        XCTAssertTrue(ids.isEmpty, "an archived session is out of the active workspace — never re-escalated")
    }

    func testEntryIdLessInboxDecisionDoesNotCoverAWaitingSession() {
        // A decision with a nil entryId (the boss couldn't resolve the session)
        // can't cover ANY waiting entry — so the waiting session is still untriaged.
        let waiting = entry("Waiting", attention: .waitingOnHuman)
        let ids = WaitingSessionReconciler.untriagedWaitingEntryIds(
            entries: [waiting],
            openInbox: [openDecision(entryId: nil)]
        )
        XCTAssertEqual(ids, [waiting.id])
    }

    func testMixedSetReturnsOnlyTheUncoveredWaitingEntries() {
        let coveredWaiting = entry("Covered", attention: .waitingOnHuman)
        let uncoveredWaiting = entry("Uncovered", attention: .waitingOnHuman)
        let idle = entry("Idle", attention: .idle)
        let ids = WaitingSessionReconciler.untriagedWaitingEntryIds(
            entries: [coveredWaiting, uncoveredWaiting, idle],
            openInbox: [openDecision(entryId: coveredWaiting.id)]
        )
        XCTAssertEqual(ids, [uncoveredWaiting.id])
    }
}
