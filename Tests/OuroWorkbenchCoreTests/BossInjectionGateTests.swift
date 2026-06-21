import XCTest
@testable import OuroWorkbenchCore

/// F3: the pure boss-injection gate. The boss can inject keystrokes (`sendInput`)
/// into a terminal even when the operator turned the auto-advance kill-switch OFF
/// (and even when the session's friend is untrusted), because the actions/MCP
/// channel never consulted the auto-advance gate. This pure seam is what the
/// authorizer folds in so EVERY channel inherits the kill-switch + per-friend trust.
///
/// Exhaustive + pure: the whole gate is unit-tested here, then the authorizer
/// integration is tested in `BossWorkbenchActionAuthorizerTests` (T1..T9).
final class BossInjectionGateTests: XCTestCase {
    private func friend(_ trust: SessionFriendTrust) -> SessionFriend {
        SessionFriend(id: "f", name: "Friend", kind: .human, trust: trust)
    }

    // MARK: - injectsLiveInput: ONLY sendInput injects live input today

    func testOnlySendInputInjectsLiveInput() {
        for kind in BossWorkbenchActionKind.allCases {
            if kind == .sendInput {
                XCTAssertTrue(kind.injectsLiveInput, "sendInput must report injectsLiveInput")
            } else {
                XCTAssertFalse(kind.injectsLiveInput, "\(kind.rawValue) must NOT inject live input")
            }
        }
    }

    // MARK: - the gate

    /// T8: every non-`sendInput` kind with a nil context is `.allow` — the
    /// kill-switch never gates a control/read verb. Covers the
    /// `injectsLiveInput == false` early-return branch for the whole enum.
    func testNonInjectingKindsAreAlwaysAllowedRegardlessOfContext() {
        for kind in BossWorkbenchActionKind.allCases where kind != .sendInput {
            XCTAssertEqual(
                evaluateBossInjectionGate(action: kind, context: nil),
                .allow,
                "\(kind.rawValue) must be allowed regardless of auto-advance context"
            )
        }
    }

    /// sendInput with NO context (the MCP-enqueue shape) is fail-closed.
    func testSendInputWithNilContextFailsClosed() {
        XCTAssertEqual(
            evaluateBossInjectionGate(action: .sendInput, context: nil),
            .deny("auto-advance state unavailable")
        )
    }

    /// sendInput with the kill-switch OFF is denied — the bypass, closed.
    func testSendInputWithKillSwitchOffIsDenied() {
        let context = BossAutoAdvanceContext(autoAdvanceEnabled: false, friend: friend(.family))
        XCTAssertEqual(
            evaluateBossInjectionGate(action: .sendInput, context: context),
            .deny("auto-advance disabled")
        )
    }

    /// sendInput with the kill-switch ON but NO friend is denied.
    func testSendInputWithNoFriendIsDenied() {
        let context = BossAutoAdvanceContext(autoAdvanceEnabled: true, friend: nil)
        XCTAssertEqual(
            evaluateBossInjectionGate(action: .sendInput, context: context),
            .deny("session has no friend")
        )
    }

    /// sendInput with the kill-switch ON but an untrusted friend is denied,
    /// naming the friend's actual trust level.
    func testSendInputWithUntrustedFriendIsDenied() {
        for trust in [SessionFriendTrust.acquaintance, .stranger] {
            let context = BossAutoAdvanceContext(autoAdvanceEnabled: true, friend: friend(trust))
            XCTAssertEqual(
                evaluateBossInjectionGate(action: .sendInput, context: context),
                .deny("friend trust is \(trust.rawValue)"),
                "an \(trust.rawValue) friend must be denied"
            )
        }
    }

    /// sendInput with kill-switch ON and a trusted friend is allowed — both
    /// trusted levels (family + friend) clear the gate.
    func testSendInputWithTrustedFriendAndKillSwitchOnIsAllowed() {
        for trust in [SessionFriendTrust.family, .friend] {
            let context = BossAutoAdvanceContext(autoAdvanceEnabled: true, friend: friend(trust))
            XCTAssertEqual(
                evaluateBossInjectionGate(action: .sendInput, context: context),
                .allow,
                "a \(trust.rawValue) friend with the kill-switch on must be allowed"
            )
        }
    }
}
