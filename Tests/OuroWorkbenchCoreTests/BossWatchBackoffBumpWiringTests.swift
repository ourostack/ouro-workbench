import XCTest
@testable import OuroWorkbenchCore

/// F8 — the headline defect: `runBossCheckIn`'s daemon-down early-return used to set
/// `bossWatchLastError` and `return` WITHOUT arming `bossWatchNextRetryAt`, so a dead
/// daemon hot-looped every poll interval forever. The fix routes BOTH the daemon-down
/// early-return AND the existing catch path through ONE shared helper
/// (`registerBossWatchFailure`) so the backoff bump can't drift between them.
///
/// The App target isn't coverage-gated, so these are source-pins (same pattern as
/// `BossWatchActionableGateTests` / `BossForwardStatusWiringTests`).
final class BossWatchBackoffBumpWiringTests: XCTestCase {
    // MARK: - the shared helper exists and arms the backoff

    /// `registerBossWatchFailure` must compute the bump via the pure
    /// `BossWatchBackoff.registerFailure` seam AND arm `bossWatchNextRetryAt` — not just
    /// touch `bossWatchLastError`. This is the single place the bump lives.
    func testRegisterBossWatchFailureHelperBumpsViaPureSeamAndArmsRetry() throws {
        let body = try registerBossWatchFailureBody()
        XCTAssertTrue(
            body.contains("BossWatchBackoff.registerFailure("),
            "the shared helper must compute the bump via the pure BossWatchBackoff.registerFailure seam"
        )
        XCTAssertTrue(
            body.contains("bossWatchNextRetryAt"),
            "the shared helper must ARM bossWatchNextRetryAt (the missing arm that caused the hot-loop)"
        )
        XCTAssertTrue(
            body.contains("bossWatchConsecutiveFailures"),
            "the shared helper must bump the consecutive-failure count"
        )
    }

    // MARK: - the daemon-down early-return routes through the helper

    /// The daemon-down `needsManualRecovery` branch must now CALL the shared helper —
    /// it can no longer just set `bossWatchLastError` and `return` (the original defect).
    func testDaemonDownBranchCallsTheSharedFailureHelper() throws {
        let branch = try daemonDownBranchBody()
        XCTAssertTrue(
            branch.contains("registerBossWatchFailure("),
            "the daemon-down early-return must route through registerBossWatchFailure so it arms the backoff (F8 headline defect)"
        )
        // It must NOT silently set lastError and bail without bumping — the original bug shape.
        XCTAssertFalse(
            branch.contains("bossWatchLastError = daemonOutcome.auditDetail"),
            "the daemon-down branch must no longer set bossWatchLastError inline and return without arming retry"
        )
    }

    // MARK: - the catch path routes through the SAME helper (no duplicated inline bump)

    /// The transport/empty catch path must call the SAME helper — not keep its own inline
    /// `bossWatchConsecutiveFailures += 1` / `bossWatchNextRetryAt = Date().addingTimeInterval(...)`
    /// duplicate, which is exactly what would let the two paths drift.
    func testCatchPathRoutesThroughTheSameHelper() throws {
        let body = try runBossCheckInPrivateBody()
        XCTAssertTrue(
            body.contains("registerBossWatchFailure("),
            "the catch path must route through the shared helper too"
        )
        XCTAssertFalse(
            body.contains("bossWatchConsecutiveFailures += 1"),
            "the catch path must not keep a duplicated inline bump — that's what drifts from the daemon-down path"
        )
        XCTAssertFalse(
            body.contains("BossWatchBackoff.delay(consecutiveFailures: bossWatchConsecutiveFailures)"),
            "the inline nextRetryAt computation must move into the shared helper (via registerFailure)"
        )
    }

    /// The mid-flight agent-switch bail-outs are NOT failures (the operator switched agents) —
    /// they must keep their bare `return` and must NOT bump the backoff.
    func testAgentSwitchBailoutsDoNotBumpBackoff() throws {
        let body = try runBossCheckInPrivateBody()
        // The success path still resets to 0.
        XCTAssertTrue(
            body.contains("bossWatchConsecutiveFailures = 0"),
            "the success path must still RESET the failure count to 0"
        )
        // Exactly the two genuine failure paths call the helper: daemon-down + catch.
        let helperCalls = body.components(separatedBy: "registerBossWatchFailure(").count - 1
        XCTAssertEqual(
            helperCalls, 2,
            "exactly the daemon-down and catch paths bump; the agent-switch guards must not (got \(helperCalls) helper calls)"
        )
    }

    // MARK: - source-pin helpers (App is not coverage-gated)

    private func runBossCheckInPrivateBody() throws -> String {
        let source = try appSource()
        let start = try XCTUnwrap(
            source.range(of: "private func runBossCheckIn(")?.upperBound,
            "could not find private runBossCheckIn in the App source"
        )
        let tail = source[start...]
        let end = tail.range(of: "\n    func ")?.lowerBound ?? tail.endIndex
        return String(tail[tail.startIndex..<end])
    }

    private func registerBossWatchFailureBody() throws -> String {
        let source = try appSource()
        let start = try XCTUnwrap(
            source.range(of: "func registerBossWatchFailure(")?.upperBound,
            "could not find registerBossWatchFailure in the App source"
        )
        let tail = source[start...]
        let end = tail.range(of: "\n    func ")?.lowerBound
            ?? tail.range(of: "\n    private func ")?.lowerBound
            ?? tail.endIndex
        return String(tail[tail.startIndex..<end])
    }

    /// The body of the `if daemonOutcome.needsManualRecovery { … }` branch.
    private func daemonDownBranchBody() throws -> String {
        let body = try runBossCheckInPrivateBody()
        let start = try XCTUnwrap(
            body.range(of: "if daemonOutcome.needsManualRecovery {")?.upperBound,
            "could not find the daemon-down needsManualRecovery branch"
        )
        let tail = body[start...]
        let end = try XCTUnwrap(
            tail.range(of: "\n        }")?.lowerBound,
            "could not find the end of the daemon-down branch"
        )
        return String(tail[tail.startIndex..<end])
    }

    private func appSource() throws -> String {
        let sourceURL = repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("OuroWorkbenchApp")
            .appendingPathComponent("OuroWorkbenchApp.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
