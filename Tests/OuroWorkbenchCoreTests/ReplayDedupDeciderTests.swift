import XCTest
@testable import OuroWorkbenchCore

/// F11b Defect 3 — the pure decision seam for replay double-execute prevention.
///
/// The action queue is at-least-once: `drain()` moves request files into
/// `processing/`, `confirmApplied(id)` deletes them AFTER the app applies, and
/// `recoverUnconfirmed()` replays anything still in `processing/` on the next
/// launch. The hazard is the apply window: the App applies the side effect
/// SYNCHRONOUSLY, then confirms OFF-MAIN in a detached task — a crash in that
/// gap leaves the `processing/` file, so recovery replays an ALREADY-APPLIED
/// request (a second keystroke / a second attributed session).
///
/// This seam is the universal guard: it decides, from the durable set of
/// applied request ids (the `applied/` marker-dir ledger), whether a request
/// the App is about to apply has already been applied — keyed STRICTLY on the
/// request id. It is id-keyed, NOT fingerprint-keyed: a boss that deliberately
/// re-issues the same effect with a NEW request id must still apply (fresh id →
/// `.apply`); only an identical-id REPLAY is skipped.
final class ReplayDedupDeciderTests: XCTestCase {
    private let requestId = UUID(uuidString: "00000000-0000-0000-0000-0000000000f1")!

    func testRequestIdAlreadyInAppliedSetSkips() {
        let decision = ReplayDedupDecider().decide(
            requestId: requestId,
            appliedRequestIds: [requestId]
        )
        XCTAssertEqual(decision, .skipAlreadyApplied)
    }

    func testRequestIdNotInAppliedSetApplies() {
        let other = UUID(uuidString: "00000000-0000-0000-0000-0000000000f2")!
        let decision = ReplayDedupDecider().decide(
            requestId: requestId,
            appliedRequestIds: [other]
        )
        XCTAssertEqual(decision, .apply)
    }

    func testEmptyAppliedSetApplies() {
        let decision = ReplayDedupDecider().decide(
            requestId: requestId,
            appliedRequestIds: []
        )
        XCTAssertEqual(decision, .apply)
    }
}
