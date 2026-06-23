import XCTest
@testable import OuroWorkbenchCore

/// Unit 1 — the debounce policy that decides when a stale readiness overlay must
/// be re-checked (scene-phase + periodic backstop, both guarded by this).
///
/// Rule: never checked yet (`lastCheckedAt == nil`) → true; else fire only once
/// `staleAfter` seconds have elapsed since the last check; a clock that skews
/// backwards (now < lastCheckedAt → negative elapsed) is NOT stale → false.
/// Pure — `now` is injected, so no wall-clock reads here.
final class AgentReadinessRefreshPolicyTests: XCTestCase {
    private let staleAfter: TimeInterval = 60

    func testNeverCheckedRefreshesImmediately() {
        XCTAssertTrue(
            AgentReadinessRefreshPolicy.shouldRefresh(
                lastCheckedAt: nil,
                now: Date(timeIntervalSince1970: 1_000),
                staleAfter: staleAfter
            ),
            "a first-ever check (lastCheckedAt == nil) must always fire"
        )
    }

    func testFreshCheckDoesNotRefresh() {
        let last = Date(timeIntervalSince1970: 1_000)
        // 59s elapsed — short of the 60s window.
        let now = last.addingTimeInterval(59)
        XCTAssertFalse(
            AgentReadinessRefreshPolicy.shouldRefresh(
                lastCheckedAt: last,
                now: now,
                staleAfter: staleAfter
            ),
            "a check that is still fresh (elapsed < staleAfter) must NOT re-fire"
        )
    }

    func testExactlyStaleAfterRefreshes() {
        let last = Date(timeIntervalSince1970: 1_000)
        // Exactly at the boundary — `>=` makes this fire.
        let now = last.addingTimeInterval(staleAfter)
        XCTAssertTrue(
            AgentReadinessRefreshPolicy.shouldRefresh(
                lastCheckedAt: last,
                now: now,
                staleAfter: staleAfter
            ),
            "elapsed == staleAfter is stale (boundary is inclusive)"
        )
    }

    func testWellPastStaleAfterRefreshes() {
        let last = Date(timeIntervalSince1970: 1_000)
        let now = last.addingTimeInterval(staleAfter * 100)
        XCTAssertTrue(
            AgentReadinessRefreshPolicy.shouldRefresh(
                lastCheckedAt: last,
                now: now,
                staleAfter: staleAfter
            ),
            "long-idle (elapsed >> staleAfter) must fire"
        )
    }

    func testClockSkewBackwardsDoesNotRefresh() {
        let last = Date(timeIntervalSince1970: 1_000)
        // now is BEFORE last (negative elapsed) — a backwards clock must not be
        // read as "stale", or skew would spam checks.
        let now = last.addingTimeInterval(-30)
        XCTAssertFalse(
            AgentReadinessRefreshPolicy.shouldRefresh(
                lastCheckedAt: last,
                now: now,
                staleAfter: staleAfter
            ),
            "negative elapsed (now < lastCheckedAt) is not stale"
        )
    }
}
