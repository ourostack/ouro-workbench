import XCTest
@testable import OuroWorkbenchCore

/// Pure-Core seams for the two first-run cold-start fixes:
///
/// FIX 1 — first-run "try again" was dead copy. The `.needsAttention` mode told the user to retry
/// but `FirstRunBootstrapView` rendered NO retry control for that mode (only the provider gate got
/// a button), and an in-place state transition won't re-fire `.onAppear`. The fix makes
/// "does this mode show a retry button" a pure, testable property (`FirstRunMode.showsRetryButton`)
/// the view reads, and wires a Try-again button gated on it.
///
/// FIX 2 — an invalid-boss first run (`.failedInvalidAgent`) collapsed into the SAME generic
/// needs-attention copy as a failed step (`.failedStep`) and offered no choose-boss affordance —
/// pointing the user at "reconnect your provider" when the real fix is PICKING A VALID BOSS. The
/// fix gives `.failedInvalidAgent` its own honest copy + its own recovery ROUTE (choose-boss),
/// distinct from `.failedStep`'s retry/reconnect route. The phase→reason→copy/route mapping is a
/// pure, exhaustively-tested Core seam (`FirstRunAttentionReason`); the view routes off it.
final class FirstRunBootstrapRetryRoutingTests: XCTestCase {

    // MARK: - FIX 1: FirstRunMode.showsRetryButton (the actionable-failure-only retry gate)

    func testNeedsAttentionModeShowsRetryButton() {
        // The actionable failure surface is the ONLY mode that offers a retry control.
        XCTAssertTrue(FirstRunMode.needsAttention.showsRetryButton)
    }

    func testNonAttentionModesDoNotShowRetryButton() {
        // Inverse-bug watch: the retry control must appear ONLY in the actionable failure mode —
        // never in a healthy/handed-off run, the mid-bootstrap run, or the provider gate (which
        // has its OWN affordance, not a generic retry).
        XCTAssertFalse(FirstRunMode.bootstrapping.showsRetryButton)
        XCTAssertFalse(FirstRunMode.parkedAwaitingProvider.showsRetryButton)
        XCTAssertFalse(FirstRunMode.agentDriven.showsRetryButton)
    }

    func testExactlyOneModeShowsTheRetryButton() {
        let retryModes = FirstRunMode.allCases.filter { $0.showsRetryButton }
        XCTAssertEqual(retryModes, [.needsAttention])
    }

    // MARK: - FIX 2: FirstRunAttentionReason from a BootstrapPhase (distinct invalid-boss route)

    func testFailedInvalidAgentMapsToChooseBossReason() {
        XCTAssertEqual(FirstRunAttentionReason(phase: .failedInvalidAgent), .invalidBoss)
    }

    func testFailedStepMapsToFailedStepReason() {
        XCTAssertEqual(FirstRunAttentionReason(phase: .failedStep(.verifyCredentials)), .failedStep)
    }

    func testNonAttentionPhasesHaveNoAttentionReason() {
        // Only the two failure phases are needs-attention; the rest carry no reason.
        XCTAssertNil(FirstRunAttentionReason(phase: .handedOff))
        XCTAssertNil(FirstRunAttentionReason(phase: .awaitingHandoff))
        XCTAssertNil(FirstRunAttentionReason(phase: .parkedAwaitingProviderConfig))
    }

    // MARK: - FIX 2: the recovery ROUTE differs per reason (choose-boss vs retry)

    func testInvalidBossRoutesToChooseBossNotRetry() {
        XCTAssertEqual(FirstRunAttentionReason.invalidBoss.recoveryAction, .chooseBoss)
    }

    func testFailedStepRoutesToRetryNotChooseBoss() {
        XCTAssertEqual(FirstRunAttentionReason.failedStep.recoveryAction, .retry)
    }

    func testTheTwoReasonsRouteToDifferentActions() {
        XCTAssertNotEqual(
            FirstRunAttentionReason.invalidBoss.recoveryAction,
            FirstRunAttentionReason.failedStep.recoveryAction,
            "invalid-boss must route to choosing a boss; a failed step must route to retry/reconnect — collapsing them is the bug"
        )
    }

    // MARK: - FIX 2: the COPY differs per reason (honest invalid-boss line, no provider-reconnect)

    func testInvalidBossCopyNamesChoosingABossAndIsSeamFree() {
        let line = FirstRunAttentionReason.invalidBoss.humanFacingLine
        assertNoCliSeam(line)
        XCTAssertFalse(line.isEmpty)
        // Honest: it points at choosing/identifying a boss, the real fix.
        XCTAssertTrue(
            line.localizedCaseInsensitiveContains("boss") || line.localizedCaseInsensitiveContains("choose"),
            "invalid-boss copy must point at choosing a boss, got: \(line)"
        )
        // And must NOT mislead toward the provider-reconnect remedy that belongs to a failed step.
        XCTAssertFalse(
            line.localizedCaseInsensitiveContains("provider"),
            "invalid-boss copy must NOT tell the user to reconnect a provider — that's the failed-step remedy, not the invalid-boss one: \(line)"
        )
    }

    func testFailedStepCopyKeepsTheProviderReconnectRemedy() {
        let line = FirstRunAttentionReason.failedStep.humanFacingLine
        assertNoCliSeam(line)
        XCTAssertFalse(line.isEmpty)
        // `.failedStep` KEEPS its provider-reconnect copy (only `.failedInvalidAgent` changed).
        XCTAssertTrue(
            line.localizedCaseInsensitiveContains("provider"),
            "failed-step copy must keep its provider-reconnect remedy, got: \(line)"
        )
    }

    func testTheTwoReasonsHaveDistinctCopy() {
        XCTAssertNotEqual(
            FirstRunAttentionReason.invalidBoss.humanFacingLine,
            FirstRunAttentionReason.failedStep.humanFacingLine,
            "invalid-boss and failed-step must read differently — the bug was collapsing both into one generic line"
        )
    }

    // MARK: - FIX 2: the button label matches the route

    func testInvalidBossButtonLabelInvitesChoosingABoss() {
        let label = FirstRunAttentionReason.invalidBoss.actionLabel
        XCTAssertFalse(label.isEmpty)
        XCTAssertTrue(
            label.localizedCaseInsensitiveContains("boss") || label.localizedCaseInsensitiveContains("choose"),
            "invalid-boss action label must invite choosing a boss, got: \(label)"
        )
    }

    func testFailedStepButtonLabelInvitesRetry() {
        let label = FirstRunAttentionReason.failedStep.actionLabel
        XCTAssertFalse(label.isEmpty)
        XCTAssertTrue(
            label.localizedCaseInsensitiveContains("try") || label.localizedCaseInsensitiveContains("again") || label.localizedCaseInsensitiveContains("retry"),
            "failed-step action label must invite a retry, got: \(label)"
        )
    }

    func testEveryReasonHasSeamFreeCopyAndLabel() {
        for reason in FirstRunAttentionReason.allCases {
            assertNoCliSeam(reason.humanFacingLine)
            assertNoCliSeam(reason.actionLabel)
            XCTAssertFalse(reason.humanFacingLine.isEmpty)
            XCTAssertFalse(reason.actionLabel.isEmpty)
        }
    }

    // MARK: - FIX 2: the presentation carries the reason so the view can route

    func testPresentationCarriesInvalidBossReason() {
        let result = BootstrapResult(phase: .failedInvalidAgent, stepOutcomes: [])
        let presentation = FirstRunBootstrapDrive().present(result: result, activeStep: nil)
        XCTAssertEqual(presentation.mode, .needsAttention)
        XCTAssertEqual(presentation.attentionReason, .invalidBoss)
    }

    func testPresentationCarriesFailedStepReason() {
        let result = BootstrapResult(
            phase: .failedStep(.verifyCredentials),
            stepOutcomes: [BootstrapStepOutcome(step: .verifyCredentials, recovery: .needsManual)]
        )
        let presentation = FirstRunBootstrapDrive().present(result: result, activeStep: nil)
        XCTAssertEqual(presentation.mode, .needsAttention)
        XCTAssertEqual(presentation.attentionReason, .failedStep)
    }

    func testNonAttentionPresentationHasNoAttentionReason() {
        let result = BootstrapResult(
            phase: .handedOff,
            stepOutcomes: BootstrapStep.allCases.map { BootstrapStepOutcome(step: $0, recovery: .verified) }
        )
        let presentation = FirstRunBootstrapDrive().present(result: result, activeStep: nil)
        XCTAssertNil(presentation.attentionReason)
    }

    func testIdlePresentationHasNoAttentionReason() {
        let presentation = FirstRunBootstrapDrive().presentIdle()
        XCTAssertNil(presentation.attentionReason)
    }

    // MARK: - Assertions

    private func assertNoCliSeam(_ value: String, file: StaticString = #filePath, line: UInt = #line) {
        let lowered = value.lowercased()
        XCTAssertFalse(lowered.contains("ouro"), "human copy leaks 'ouro': \(value)", file: file, line: line)
        XCTAssertFalse(lowered.contains("daemon"), "human copy leaks 'daemon': \(value)", file: file, line: line)
        XCTAssertFalse(lowered.contains("hatch"), "human copy leaks 'hatch': \(value)", file: file, line: line)
        XCTAssertFalse(lowered.contains("vault"), "human copy leaks 'vault': \(value)", file: file, line: line)
        XCTAssertFalse(lowered.contains("mcp"), "human copy leaks 'mcp': \(value)", file: file, line: line)
        XCTAssertFalse(lowered.contains("--"), "human copy leaks a CLI flag: \(value)", file: file, line: line)
    }
}
