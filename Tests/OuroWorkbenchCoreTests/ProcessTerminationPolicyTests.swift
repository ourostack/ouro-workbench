import XCTest
@testable import OuroWorkbenchCore

final class ProcessTerminationPolicyTests: XCTestCase {
    func testRecoveryAttemptTerminationRequiresManualActionWhenNotUserStopped() {
        let policy = ProcessTerminationPolicy()

        XCTAssertEqual(
            policy.statusAfterTermination(recoveryAction: .autoResume, manuallyTerminated: false),
            .manualActionNeeded
        )
        XCTAssertEqual(
            policy.statusAfterTermination(recoveryAction: .respawn, manuallyTerminated: false),
            .manualActionNeeded
        )
    }

    func testManualStopAndOrdinaryExitRemainExited() {
        let policy = ProcessTerminationPolicy()

        XCTAssertEqual(
            policy.statusAfterTermination(recoveryAction: .autoResume, manuallyTerminated: true),
            .exited
        )
        XCTAssertEqual(
            policy.statusAfterTermination(recoveryAction: nil, manuallyTerminated: false),
            .exited
        )
    }
}
