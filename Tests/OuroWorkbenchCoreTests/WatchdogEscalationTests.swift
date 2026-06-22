import XCTest
@testable import OuroWorkbenchCore

/// F8b — the pure kill-escalation decision behind `ProcessWatchdog` AND `ProcessIOBox`.
/// A wedged child that ignores SIGTERM must be SIGKILLed past a grace window; but a
/// `killpg` would reap a SHARED process group (a child spawned with `Process()` shares
/// Workbench's pgid), so `.killGroup` is the load-bearing safety gate: it is returned
/// ONLY when the child was proven to be in its OWN group (`childInOwnGroup: true`) — the
/// same boolean that selected the `SpawnInOwnGroup` path at the call site.
final class WatchdogEscalationTests: XCTestCase {
    private let grace = 2.0

    func testBeforeDeadlineIsNone() {
        XCTAssertEqual(
            WatchdogEscalation.nextSignal(elapsedSinceDeadline: -0.1, graceSeconds: grace, childInOwnGroup: false),
            .none
        )
        // Own-group does not change the pre-deadline arm.
        XCTAssertEqual(
            WatchdogEscalation.nextSignal(elapsedSinceDeadline: -5, graceSeconds: grace, childInOwnGroup: true),
            .none
        )
    }

    func testWithinGraceIsTerminate() {
        // At the deadline and through the grace window: SIGTERM only — give a
        // cooperative child room to flush + exit before escalating.
        XCTAssertEqual(
            WatchdogEscalation.nextSignal(elapsedSinceDeadline: 0, graceSeconds: grace, childInOwnGroup: false),
            .terminate
        )
        XCTAssertEqual(
            WatchdogEscalation.nextSignal(elapsedSinceDeadline: 1.9, graceSeconds: grace, childInOwnGroup: true),
            .terminate,
            "still within grace → terminate, regardless of own-group"
        )
    }

    func testPastGraceWithoutOwnGroupIsKillChildOnly() {
        // THE safety default: a child that survived SIGTERM through grace, NOT in its own
        // group → SIGKILL the child pid ONLY. Never killpg (that would kill Workbench).
        XCTAssertEqual(
            WatchdogEscalation.nextSignal(elapsedSinceDeadline: 2.0, graceSeconds: grace, childInOwnGroup: false),
            .killChild
        )
        XCTAssertEqual(
            WatchdogEscalation.nextSignal(elapsedSinceDeadline: 10, graceSeconds: grace, childInOwnGroup: false),
            .killChild
        )
    }

    func testPastGraceWithOwnGroupIsKillGroup() {
        // The ONLY arm that returns .killGroup: past grace AND the child is provably in
        // its own process group. The live consumer is ProcessIOBox.forceKill (mcp-serve).
        XCTAssertEqual(
            WatchdogEscalation.nextSignal(elapsedSinceDeadline: 2.0, graceSeconds: grace, childInOwnGroup: true),
            .killGroup
        )
        XCTAssertEqual(
            WatchdogEscalation.nextSignal(elapsedSinceDeadline: 10, graceSeconds: grace, childInOwnGroup: true),
            .killGroup
        )
    }

    func testKillGroupIsExclusiveToOwnGroup() {
        // Explicit safety pin: the ONLY difference between killChild and killGroup at the
        // same elapsed time is the childInOwnGroup flag — they can't drift apart.
        let elapsed = grace + 5
        XCTAssertEqual(
            WatchdogEscalation.nextSignal(elapsedSinceDeadline: elapsed, graceSeconds: grace, childInOwnGroup: false),
            .killChild
        )
        XCTAssertEqual(
            WatchdogEscalation.nextSignal(elapsedSinceDeadline: elapsed, graceSeconds: grace, childInOwnGroup: true),
            .killGroup
        )
    }
}
