import XCTest
@testable import OuroWorkbenchCore

/// U42: the boss-watch wake gate must read the SAME shared `RecoveryDigest`
/// needs-action derivation every other recovery surface uses (the drill's count,
/// the sidebar). A pure-reconnect workspace — only lossless `.reattach` survivors
/// — needs no action, so it must NOT wake the boss; a real auto-recoverable or
/// needs-you session must.
///
/// Two halves:
///  - the pure predicate (`RecoveryDigest.hasNeedsAction`) is exercised directly,
///  - the App wiring is source-pinned (the App target isn't coverage-gated), the
///    same pattern `BossForwardStatusWiringTests` / `ReadinessActuatorStatusWiringTests`
///    use.
final class BossWatchActionableGateTests: XCTestCase {
    private func plan(_ action: RecoveryAction) -> RecoveryPlan {
        RecoveryPlan(entryId: UUID(), runId: nil, action: action, reason: "r")
    }

    /// The gate predicate: reattach-only is NOT a wake; a real needs-action is.
    func testReattachOnlyWorkspaceIsNotActionableForBossWatch() {
        let reattachOnly = RecoveryDigest(plans: [plan(.reattach), plan(.reattach)])
        XCTAssertFalse(reattachOnly.hasNeedsAction)

        let withAutoResume = RecoveryDigest(plans: [plan(.reattach), plan(.autoResume)])
        XCTAssertTrue(withAutoResume.hasNeedsAction)

        let withNeedsYou = RecoveryDigest(plans: [plan(.reattach), plan(.manualActionNeeded)])
        XCTAssertTrue(withNeedsYou.hasNeedsAction)
    }

    /// The boss-watch tick gates `hasActionableState` on the shared digest's
    /// needs-action signal, not a bespoke `needsRecovery.isEmpty` recompute — so
    /// the wake decision can't drift from the drill / sidebar.
    func testBossWatchGatesOnSharedDigestNeedsAction() throws {
        let tick = try bossWatchTickBody()
        XCTAssertTrue(
            tick.contains("recoveryDigest.hasNeedsAction"),
            "the boss-watch gate must read the shared RecoveryDigest needs-action signal (U42)"
        )
        // It must no longer key its actionable gate off the bespoke
        // `summary.needsRecovery` recompute.
        XCTAssertFalse(
            tick.contains("summary.needsRecovery.isEmpty"),
            "the boss-watch gate must not recompute actionability via summary.needsRecovery (U42)"
        )
    }

    // MARK: - source pinning helpers (App is not coverage-gated)

    private func bossWatchTickBody() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        let start = try XCTUnwrap(
            source.range(of: "func runBossWatchTick(force: Bool) async {")?.upperBound,
            "could not find runBossWatchTick in the App source"
        )
        let tail = source[start...]
        let end = tail.range(of: "\n    func ")?.lowerBound ?? tail.endIndex
        return String(tail[tail.startIndex..<end])
    }
}
