import XCTest
@testable import OuroWorkbenchCore

/// F1 — cold-start agent creation is no longer a silent dead end.
///
/// `runHeadless` now reports the `ouro hatch` exit (seam 1), and `classifyColdStart` folds that
/// exit together with a post-hatch `ouro check` verdict (seam 2) into an honest outcome. These
/// tests ARE the decision table from the F1 spec — full line+region coverage of the pure seam.
final class ColdStartClassifierTests: XCTestCase {
    // MARK: - Decision table

    func testLaunchFailureIsAlwaysHatchLaunchError() {
        // `hatchExitCode == nil` means the hatch process never even launched (`.launchFailed`).
        // No amount of probe verdict can rescue that — it's a launch error regardless of verdict.
        for verdict in allVerdictsIncludingNil() {
            XCTAssertEqual(
                ProviderConfigForm.classifyColdStart(hatchExitCode: nil, checkVerdict: verdict),
                .failed(reason: .hatchLaunchError),
                "launch failure must classify as hatchLaunchError for verdict \(String(describing: verdict))"
            )
        }
    }

    func testNonZeroExitIsAlwaysHatchNonZeroExit() {
        // A non-zero hatch exit is a real failure regardless of what the probe later says — the
        // agent.json/credential state is untrustworthy. (`1` is the canonical non-zero case.)
        for verdict in allVerdictsIncludingNil() {
            XCTAssertEqual(
                ProviderConfigForm.classifyColdStart(hatchExitCode: 1, checkVerdict: verdict),
                .failed(reason: .hatchNonZeroExit),
                "non-zero exit must classify as hatchNonZeroExit for verdict \(String(describing: verdict))"
            )
        }
    }

    func testOtherNonZeroExitCodesAlsoClassifyAsHatchNonZeroExit() {
        // Any non-zero code (not just 1) is hatchNonZeroExit — the branch is `code != 0`.
        XCTAssertEqual(
            ProviderConfigForm.classifyColdStart(hatchExitCode: 127, checkVerdict: .working),
            .failed(reason: .hatchNonZeroExit)
        )
    }

    func testCleanExitAndWorkingVerdictIsReady() {
        // The only path to `.ready`: hatch exited 0 AND the post-hatch check probe says `.working`.
        XCTAssertEqual(
            ProviderConfigForm.classifyColdStart(hatchExitCode: 0, checkVerdict: .working),
            .ready
        )
    }

    func testCleanExitButVaultLockedNeedsVaultSetup() {
        // The actual F1 failure shape: hatch exits 0 (agent.json written) but the credential step
        // left no usable vault, so the probe reports vault-locked → route to vault setup, NOT ready.
        XCTAssertEqual(
            ProviderConfigForm.classifyColdStart(hatchExitCode: 0, checkVerdict: .vaultLocked),
            .needsVaultSetup
        )
    }

    func testCleanExitButUnauthorizedNeedsVaultSetup() {
        // A 401 after a clean hatch is also a "created but not connected" state — same destination
        // as vault-locked: the agent exists but its provider isn't usable yet.
        XCTAssertEqual(
            ProviderConfigForm.classifyColdStart(hatchExitCode: 0, checkVerdict: .unauthorized),
            .needsVaultSetup
        )
    }

    func testCleanExitButUnreachableCannotBeConfirmed() {
        // Network-unreachable after a clean hatch: we genuinely can't confirm the agent is good,
        // so we don't claim success and we don't falsely claim "needs vault" either.
        XCTAssertEqual(
            ProviderConfigForm.classifyColdStart(hatchExitCode: 0, checkVerdict: .unreachable),
            .failed(reason: .couldNotConfirm)
        )
    }

    func testCleanExitButIndeterminateCannotBeConfirmed() {
        // Indeterminate probe output → couldn't confirm.
        XCTAssertEqual(
            ProviderConfigForm.classifyColdStart(hatchExitCode: 0, checkVerdict: .indeterminate),
            .failed(reason: .couldNotConfirm)
        )
    }

    func testCleanExitButProbeTimedOutCannotBeConfirmed() {
        // `checkVerdict == nil` means the probe timed out / couldn't run (e.g. a flaky daemon hang
        // hit the short watchdog). We degrade to "couldn't confirm" — NOT a false green.
        XCTAssertEqual(
            ProviderConfigForm.classifyColdStart(hatchExitCode: 0, checkVerdict: nil),
            .failed(reason: .couldNotConfirm)
        )
    }

    // MARK: - humanFacingLine (seam-free per outcome)

    func testReadyLineNamesTheAgentAndIsSeamFree() {
        let line = ColdStartOutcome.ready.humanFacingLine(agentName: "Scout")
        XCTAssertTrue(line.contains("Scout"), "ready copy must name the agent: \(line)")
        XCTAssertTrue(line.contains("connected"), "ready copy should read as connected: \(line)")
        assertSeamFree(line)
    }

    func testNeedsVaultSetupLineNamesTheAgentAndIsSeamFree() {
        let line = ColdStartOutcome.needsVaultSetup.humanFacingLine(agentName: "Scout")
        XCTAssertTrue(line.contains("Scout"), "needsVaultSetup copy must name the agent: \(line)")
        assertSeamFree(line)
    }

    func testFailedLineNamesTheAgentAndIsSeamFreeForEveryReason() {
        for reason in ColdStartFailureReason.allReasonsForTest() {
            let line = ColdStartOutcome.failed(reason: reason).humanFacingLine(agentName: "Scout")
            XCTAssertTrue(line.contains("Scout"), "\(reason) copy must name the agent: \(line)")
            assertSeamFree(line)
        }
    }

    func testAuditReasonIsStableNonHumanTokenPerOutcome() {
        // The action log's `result:` line uses auditReason — a stable token, not human copy.
        XCTAssertEqual(ColdStartOutcome.ready.auditReason, "ready")
        XCTAssertEqual(ColdStartOutcome.needsVaultSetup.auditReason, "needsVaultSetup")
        XCTAssertEqual(ColdStartOutcome.failed(reason: .hatchLaunchError).auditReason, "hatchLaunchError")
        XCTAssertEqual(ColdStartOutcome.failed(reason: .hatchNonZeroExit).auditReason, "hatchNonZeroExit")
        XCTAssertEqual(ColdStartOutcome.failed(reason: .couldNotConfirm).auditReason, "couldNotConfirm")
    }

    func testOutcomeAndReasonAreEquatableAndRawRepresentable() {
        // The reason carries a stable rawValue (used in the audit log); pin the round-trip.
        XCTAssertEqual(ColdStartFailureReason.hatchLaunchError.rawValue, "hatchLaunchError")
        XCTAssertEqual(ColdStartFailureReason.hatchNonZeroExit.rawValue, "hatchNonZeroExit")
        XCTAssertEqual(ColdStartFailureReason.couldNotConfirm.rawValue, "couldNotConfirm")
        XCTAssertNotEqual(ColdStartOutcome.ready, .needsVaultSetup)
        XCTAssertNotEqual(
            ColdStartOutcome.failed(reason: .hatchLaunchError),
            .failed(reason: .couldNotConfirm)
        )
    }

    // MARK: - Helpers

    private func allVerdictsIncludingNil() -> [ProviderConnectionVerdict?] {
        ProviderConnectionVerdict.allCases.map { Optional($0) } + [nil]
    }

    private func assertSeamFree(_ string: String, file: StaticString = #filePath, line: UInt = #line) {
        let lowered = string.lowercased()
        for seam in ["ouro", "hatch", "vault", "--"] {
            XCTAssertFalse(
                lowered.contains(seam),
                "human-facing cold-start copy must not expose the seam '\(seam)': \(string)",
                file: file,
                line: line
            )
        }
    }
}

private extension ColdStartFailureReason {
    /// Every reason — drives the seam-free copy assertion across all failure flavors.
    static func allReasonsForTest() -> [ColdStartFailureReason] {
        [.hatchLaunchError, .hatchNonZeroExit, .couldNotConfirm]
    }
}
