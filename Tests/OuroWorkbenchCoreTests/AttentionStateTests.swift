import XCTest
@testable import OuroWorkbenchCore

final class AttentionStateTests: XCTestCase {
    func testNeedsHumanCoversWaitingReviewAndBlocked() {
        XCTAssertTrue(AttentionState.waitingOnHuman.needsHuman)
        XCTAssertTrue(AttentionState.needsBossReview.needsHuman)
        XCTAssertTrue(AttentionState.blocked.needsHuman)
    }

    func testActiveAndIdleDoNotNeedHuman() {
        XCTAssertFalse(AttentionState.active.needsHuman)
        XCTAssertFalse(AttentionState.idle.needsHuman)
    }

    func testUnknownRawValueDecodesToIdleAndDoesNotNeedHuman() throws {
        let decoded = try JSONDecoder().decode(AttentionState.self, from: Data("\"banana\"".utf8))
        XCTAssertEqual(decoded, .idle)
        XCTAssertFalse(decoded.needsHuman)
    }
}
