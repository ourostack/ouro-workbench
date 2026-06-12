import Foundation
import XCTest
@testable import OuroWorkbenchCore

/// `ensureDaemon` as an agent-issuable action wraps Slice 0's `DaemonManager.ensureRunning()`.
/// Recovery-truth comes from the existing `DaemonRecoveryTruth` classification (the post-start
/// verify probe), never an exit code. These tests cover the agent-action surfacing layer
/// (`DaemonEnsureActionOutcome`) that adapts a `DaemonStartOutcome` for `bossAppliedActions`.
final class DaemonEnsureActionTests: XCTestCase {
    private func outcome(_ recovery: DaemonRecoveryTruth, liveness: DaemonLiveness, attempted: Bool) -> DaemonEnsureActionOutcome {
        DaemonEnsureActionOutcome(
            start: DaemonStartOutcome(recovery: recovery, liveness: liveness, startAttempted: attempted)
        )
    }

    // MARK: - Recovery-truth passthrough (from DaemonManager's post-start probe, never exit code)

    func testNeedsManualRecoveryOnlyOnNeedsManual() {
        XCTAssertFalse(outcome(.resumed, liveness: .up, attempted: false).needsManualRecovery)
        XCTAssertFalse(outcome(.respawned, liveness: .up, attempted: true).needsManualRecovery)
        XCTAssertTrue(outcome(.needsManual, liveness: .down, attempted: true).needsManualRecovery)
    }

    // MARK: - Cohesive copy — a non-nil seam-free line on EVERY outcome (unlike the silent
    // resumed check-in line, an agent action always reports back)

    func testHumanFacingLineIsNonEmptyAndSeamFreeForEveryOutcome() {
        let cases: [DaemonEnsureActionOutcome] = [
            outcome(.resumed, liveness: .up, attempted: false),
            outcome(.respawned, liveness: .up, attempted: true),
            outcome(.needsManual, liveness: .down, attempted: true),
        ]
        for c in cases {
            XCTAssertFalse(c.humanFacingLine.isEmpty)
            XCTAssertFalse(c.humanFacingLine.lowercased().contains("ouro"))
            XCTAssertFalse(c.humanFacingLine.lowercased().contains("daemon"))
            XCTAssertFalse(c.humanFacingLine.contains("ouro up"))
        }
    }

    func testResumedAndRespawnedHaveDistinctReadyLines() {
        XCTAssertNotEqual(
            outcome(.resumed, liveness: .up, attempted: false).humanFacingLine,
            outcome(.needsManual, liveness: .down, attempted: true).humanFacingLine
        )
    }

    // MARK: - Audit detail carries the raw verb (passthrough from DaemonStartOutcome)

    func testAuditDetailCarriesRawDaemonVerb() {
        XCTAssertTrue(outcome(.respawned, liveness: .up, attempted: true).auditDetail.lowercased().contains("ouro up"))
        XCTAssertTrue(outcome(.resumed, liveness: .up, attempted: false).auditDetail.lowercased().contains("daemon"))
    }

    // MARK: - succeeded flag is true ONLY when the daemon is genuinely up

    func testSucceededTrueOnlyWhenUp() {
        XCTAssertTrue(outcome(.resumed, liveness: .up, attempted: false).succeeded)
        XCTAssertTrue(outcome(.respawned, liveness: .up, attempted: true).succeeded)
        XCTAssertFalse(outcome(.needsManual, liveness: .down, attempted: true).succeeded)
    }
}
