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

    // MARK: - registerFailure (F8 — the shared bump the daemon-down + catch paths both call)

    func testRegisterFailureFromZeroArmsBaseDelay() {
        // 0 → 1 consecutive failure: the very first bump waits exactly `base` (60s),
        // matching delay(1) — no longer a 0-delay hot-loop.
        let r = BossWatchBackoff.registerFailure(consecutiveFailures: 0, now: now, base: 60, cap: 900)
        XCTAssertEqual(r.consecutiveFailures, 1)
        XCTAssertEqual(r.nextRetryAt, now.addingTimeInterval(60))
        XCTAssertEqual(r.nextRetryAt.timeIntervalSince(now), BossWatchBackoff.delay(consecutiveFailures: 1, base: 60, cap: 900))
    }

    func testRegisterFailureDoublesAndCaps() {
        // N → N+1 doubles the delay (mirror of the catch-path math) until the cap.
        let r1 = BossWatchBackoff.registerFailure(consecutiveFailures: 1, now: now, base: 60, cap: 900)
        XCTAssertEqual(r1.consecutiveFailures, 2)
        XCTAssertEqual(r1.nextRetryAt, now.addingTimeInterval(120))

        // Already past the cap: bumping again keeps the delay clamped at `cap`.
        let rCap = BossWatchBackoff.registerFailure(consecutiveFailures: 99, now: now, base: 60, cap: 900)
        XCTAssertEqual(rCap.consecutiveFailures, 100)
        XCTAssertEqual(rCap.nextRetryAt, now.addingTimeInterval(900))
    }

    func testRegisterFailureNextRetryExcludesImmediateRetry() {
        // Composes with mayAttempt: right after a bump, an immediate retry is gated out;
        // a retry AT/after the armed instant is allowed.
        let r = BossWatchBackoff.registerFailure(consecutiveFailures: 0, now: now)
        XCTAssertFalse(BossWatchBackoff.mayAttempt(now: now, nextRetryAt: r.nextRetryAt),
                       "an immediate retry after a failure must be deferred")
        XCTAssertTrue(BossWatchBackoff.mayAttempt(now: r.nextRetryAt, nextRetryAt: r.nextRetryAt),
                      "a retry at the armed instant is allowed")
    }

    func testRegisterFailureDefaultBaseAndCap() {
        // Default args mirror delay()'s defaults (base 60, cap 900) so callers can omit them.
        let r = BossWatchBackoff.registerFailure(consecutiveFailures: 0, now: now)
        XCTAssertEqual(r.nextRetryAt, now.addingTimeInterval(60))
    }
}
