import XCTest
@testable import OuroWorkbenchCore

/// Seam (#F9 wiring): the pure decision the App's handoff `statusPing` closure delegates
/// to. It folds the boss-native `status` round-trip result together with the `tools/list`
/// injection probe into ONE handoff outcome — and critically distinguishes a CONFIRMED
/// `.absent` (the hard "tools stripped" blocker) from a probe that couldn't answer
/// (timeout / spawn error → stay awaiting, UNCONFIRMED, never a false "too old").
final class WorkbenchHandoffGateTests: XCTestCase {

    // A failed status round-trip is never a handoff, regardless of the probe.
    func testStatusPingFailureIsNotHandedOff() {
        let decision = WorkbenchHandoffGate.decide(statusPingSucceeded: false, injectionProbe: .confirmed(.present))
        XCTAssertEqual(decision.outcome, .awaitingHandoff)
        XCTAssertFalse(decision.toolsConfirmedStripped)
        XCTAssertFalse(decision.isHandedOff)
    }

    // status ok + confirmed present ⇒ the only path that hands off.
    func testStatusOkAndToolsPresentHandsOff() {
        let decision = WorkbenchHandoffGate.decide(statusPingSucceeded: true, injectionProbe: .confirmed(.present))
        XCTAssertEqual(decision.outcome, .handedOff)
        XCTAssertTrue(decision.isHandedOff)
        XCTAssertFalse(decision.toolsConfirmedStripped)
    }

    // status ok + CONFIRMED absent ⇒ the hard blocker: tools stripped, stay awaiting,
    // and flag that the registration should flip to .toolsNotInjected.
    func testStatusOkButToolsConfirmedAbsentIsTheHardBlocker() {
        let decision = WorkbenchHandoffGate.decide(statusPingSucceeded: true, injectionProbe: .confirmed(.absent))
        XCTAssertEqual(decision.outcome, .toolsStripped)
        XCTAssertFalse(decision.isHandedOff, "never report handedOff with stripped tools")
        XCTAssertTrue(decision.toolsConfirmedStripped)
    }

    // status ok + probe could not answer (timeout / spawn error) ⇒ stay awaiting but
    // UNCONFIRMED — NOT a blocker. A slow cold start must not false-report "too old".
    func testStatusOkButProbeUnconfirmedStaysAwaitingNotBlocked() {
        let decision = WorkbenchHandoffGate.decide(statusPingSucceeded: true, injectionProbe: .unconfirmed)
        XCTAssertEqual(decision.outcome, .awaitingHandoff)
        XCTAssertFalse(decision.isHandedOff)
        XCTAssertFalse(decision.toolsConfirmedStripped, "an unanswered probe is not evidence of stripping")
    }

    // The App closure returns a Bool to AgentReadinessBootstrap; only .handedOff is true.
    func testReadyForBootstrapIsTrueOnlyWhenHandedOff() {
        XCTAssertTrue(WorkbenchHandoffGate.decide(statusPingSucceeded: true, injectionProbe: .confirmed(.present)).isHandedOff)
        XCTAssertFalse(WorkbenchHandoffGate.decide(statusPingSucceeded: true, injectionProbe: .confirmed(.absent)).isHandedOff)
        XCTAssertFalse(WorkbenchHandoffGate.decide(statusPingSucceeded: true, injectionProbe: .unconfirmed).isHandedOff)
        XCTAssertFalse(WorkbenchHandoffGate.decide(statusPingSucceeded: false, injectionProbe: .unconfirmed).isHandedOff)
    }
}
