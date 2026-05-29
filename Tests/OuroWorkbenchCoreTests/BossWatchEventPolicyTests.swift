import XCTest
@testable import OuroWorkbenchCore

final class BossWatchEventPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testTriggersWhenEnabledIdleAndNeverRunBefore() {
        XCTAssertTrue(BossWatchEventPolicy.shouldTriggerCheckIn(
            watchEnabled: true, busy: false, lastTriggerAt: nil, now: now, cooldown: 15
        ))
    }

    func testDoesNotTriggerWhenWatchDisabled() {
        XCTAssertFalse(BossWatchEventPolicy.shouldTriggerCheckIn(
            watchEnabled: false, busy: false, lastTriggerAt: nil, now: now, cooldown: 15
        ))
    }

    func testDoesNotTriggerWhenBusy() {
        XCTAssertFalse(BossWatchEventPolicy.shouldTriggerCheckIn(
            watchEnabled: true, busy: true, lastTriggerAt: nil, now: now, cooldown: 15
        ))
    }

    func testRespectsCooldown() {
        let recent = now.addingTimeInterval(-5)
        XCTAssertFalse(BossWatchEventPolicy.shouldTriggerCheckIn(
            watchEnabled: true, busy: false, lastTriggerAt: recent, now: now, cooldown: 15
        ), "5s < 15s cooldown")
    }

    func testTriggersAfterCooldownElapsed() {
        let old = now.addingTimeInterval(-20)
        XCTAssertTrue(BossWatchEventPolicy.shouldTriggerCheckIn(
            watchEnabled: true, busy: false, lastTriggerAt: old, now: now, cooldown: 15
        ), "20s > 15s cooldown")
    }

    // MARK: - Backoff

    func testBackoffDelayGrowsExponentiallyAndCaps() {
        XCTAssertEqual(BossWatchBackoff.delay(consecutiveFailures: 0), 0)
        XCTAssertEqual(BossWatchBackoff.delay(consecutiveFailures: 1, base: 60), 60)
        XCTAssertEqual(BossWatchBackoff.delay(consecutiveFailures: 2, base: 60), 120)
        XCTAssertEqual(BossWatchBackoff.delay(consecutiveFailures: 3, base: 60), 240)
        XCTAssertEqual(BossWatchBackoff.delay(consecutiveFailures: 99, base: 60, cap: 900), 900)
    }

    func testMayAttemptRespectsNextRetry() {
        XCTAssertTrue(BossWatchBackoff.mayAttempt(now: now, nextRetryAt: nil))
        XCTAssertFalse(BossWatchBackoff.mayAttempt(now: now, nextRetryAt: now.addingTimeInterval(30)))
        XCTAssertTrue(BossWatchBackoff.mayAttempt(now: now, nextRetryAt: now.addingTimeInterval(-1)))
    }
}
