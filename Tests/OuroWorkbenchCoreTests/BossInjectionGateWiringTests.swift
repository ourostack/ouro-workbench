import XCTest
@testable import OuroWorkbenchCore

/// F3 — the app-apply wiring that feeds the authorizer the real auto-advance
/// context (the operator's kill-switch + the session's effective friend) so the
/// folded-in `evaluateBossInjectionGate` actually fires on the authoritative
/// actions channel. The pure gate + authorizer integration are tested directly
/// (BossInjectionGateTests / BossWorkbenchActionAuthorizerTests T1..T9); this
/// SOURCE-PINS the App wiring (the App target isn't coverage-gated), the same
/// pattern `BossWatchActionableGateTests` / `BossForwardStatusWiringTests` use.
///
/// Without this pin, a refactor could silently stop building/passing the context
/// to `authorize` — defaulting it to `nil` would re-open F3 for the SAFE-input
/// case (a benign `y` would slip the kill-switch) without breaking any other test,
/// because nil only fail-closes; it never asserts the kill-switch's actual state.
final class BossInjectionGateWiringTests: XCTestCase {
    /// `applyBossAction` must build a `BossAutoAdvanceContext` from the operator's
    /// kill-switch (`bossAutoAdvanceEnabled`) and the session's effective friend
    /// (the SAME `effectiveFriend(for:fallback: machineOwner)` shape the decisions
    /// channel `recordBossDecisions` uses), and pass it to `authorize` as
    /// `autoAdvanceContext`.
    func testApplyBossActionBuildsAndPassesAutoAdvanceContextToAuthorize() throws {
        let body = try applyBossActionBody()

        // It builds the context from the kill-switch + effective friend.
        XCTAssertTrue(
            body.contains("BossAutoAdvanceContext("),
            "applyBossAction must build a BossAutoAdvanceContext for the authorizer (F3)"
        )
        XCTAssertTrue(
            body.contains("autoAdvanceEnabled: bossAutoAdvanceEnabled"),
            "the context's kill-switch must be the operator's bossAutoAdvanceEnabled (F3)"
        )
        XCTAssertTrue(
            body.contains("effectiveFriend(for: entry"),
            "the context's friend must be the session's effective friend (F3)"
        )
        XCTAssertTrue(
            body.contains("SessionFriend.machineOwner()"),
            "the effective friend must fall back to the machine owner, as the decisions channel does (F3)"
        )

        // It passes the built context into the authorizer call.
        XCTAssertTrue(
            body.contains("autoAdvanceContext: autoAdvanceContext"),
            "applyBossAction must pass the built context to authorize as autoAdvanceContext (F3)"
        )
        // And the authorize call still forwards the live prompt (the safety floor
        // must keep firing — F3 is additive, not a replacement).
        XCTAssertTrue(
            body.contains("livePrompt: livePrompt"),
            "the authorize call must still forward livePrompt so the safety floor keeps firing (F3 is additive)"
        )
    }

    // MARK: - source pinning helpers (App is not coverage-gated)

    /// The body of `applyBossAction` from its declaration to the next top-level
    /// `private func` / `func` boundary — enough to span the context build and the
    /// `authorize(...)` call.
    private func applyBossActionBody() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        let start = try XCTUnwrap(
            source.range(of: "private func applyBossAction(_ action: BossWorkbenchAction, source: String, requestId: UUID? = nil) -> String {")?.upperBound,
            "could not find applyBossAction in the App source"
        )
        let tail = source[start...]
        // The authorize call lives well inside the function; bound the slice at
        // the next function declaration so we read the whole body.
        let end = tail.range(of: "\n    private func ")?.lowerBound
            ?? tail.range(of: "\n    func ")?.lowerBound
            ?? tail.endIndex
        return String(tail[tail.startIndex..<end])
    }
}
