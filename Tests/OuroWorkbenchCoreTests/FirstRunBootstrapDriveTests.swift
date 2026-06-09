import XCTest
@testable import OuroWorkbenchCore

/// Unit 4.3 — the pure presentation logic that drives the first-run bootstrap UI and the
/// native-bootstrap → agent-driven (Layer B) handoff. The SwiftUI view layer is thin wiring
/// over this; all the branching / sequencing / copy lives here so it unit-tests without a live
/// daemon/agent.
final class FirstRunBootstrapDriveTests: XCTestCase {

    // MARK: - Per-step human-facing active copy (seam-free)

    func testEveryStepHasASeamFreeActiveLine() {
        for step in BootstrapStep.allCases {
            assertNoCliSeam(step.humanFacingActiveLine)
            XCTAssertFalse(step.humanFacingActiveLine.isEmpty)
        }
    }

    func testActiveLinesAreDistinctPerStep() {
        let lines = BootstrapStep.allCases.map(\.humanFacingActiveLine)
        XCTAssertEqual(Set(lines).count, lines.count, "each step should have its own progress copy")
    }

    func testProviderStepActiveLineNamesTheHumanGate() {
        // S2 is the one human gate: its copy should ask the human to connect, never expose a CLI.
        let line = BootstrapStep.providerConfig.humanFacingActiveLine
        assertNoCliSeam(line)
        XCTAssertTrue(line.localizedCaseInsensitiveContains("connect") || line.localizedCaseInsensitiveContains("provider"))
    }

    // MARK: - Step row view-model

    func testPendingStepRowIsSeamFreeAndNotActive() {
        let row = BootstrapStepProgress(step: .vaultSync, state: .pending)
        assertNoCliSeam(row.humanFacingLine)
        XCTAssertFalse(row.isActive)
        XCTAssertFalse(row.isTerminalFailure)
        // Audit detail is the ONE place a raw verb is allowed.
        XCTAssertFalse(row.auditDetail.isEmpty)
    }

    func testActiveStepRowReportsActive() {
        let row = BootstrapStepProgress(step: .ensureDaemon, state: .active)
        XCTAssertTrue(row.isActive)
        assertNoCliSeam(row.humanFacingLine)
    }

    func testVerifiedStepRowIsDoneNotFailure() {
        let row = BootstrapStepProgress(step: .registerWorkbenchMCP, state: .verified)
        XCTAssertTrue(row.isDone)
        XCTAssertFalse(row.isTerminalFailure)
        assertNoCliSeam(row.humanFacingLine)
    }

    func testHaltedStepRowIsTerminalFailureAndHonest() {
        let row = BootstrapStepProgress(step: .verifyCredentials, state: .halted)
        XCTAssertTrue(row.isTerminalFailure)
        assertNoCliSeam(row.humanFacingLine)
        // Honest: it never claims success.
        XCTAssertFalse(row.humanFacingLine.localizedCaseInsensitiveContains("ready"))
    }

    func testParkedProviderRowIsTheHumanGate() {
        let row = BootstrapStepProgress(step: .providerConfig, state: .awaitingHuman)
        XCTAssertTrue(row.isAwaitingHuman)
        assertNoCliSeam(row.humanFacingLine)
    }

    func testEveryStepHasASeamFreeDoneLine() {
        // Reading the verified-row human line exercises the per-step "done" copy for every step.
        for step in BootstrapStep.allCases {
            let row = BootstrapStepProgress(step: step, state: .verified)
            assertNoCliSeam(row.humanFacingLine)
            XCTAssertFalse(row.humanFacingLine.isEmpty)
        }
    }

    func testSkippedRowReadsAsDoneAndSeamFree() {
        let row = BootstrapStepProgress(step: .vaultSync, state: .skipped)
        assertNoCliSeam(row.humanFacingLine)
        XCTAssertFalse(row.humanFacingLine.isEmpty)
        XCTAssertFalse(row.isTerminalFailure)
    }

    func testStepRowIdentifierMatchesTheStepRawValue() {
        let row = BootstrapStepProgress(step: .registerWorkbenchMCP, state: .pending)
        XCTAssertEqual(row.id, BootstrapStep.registerWorkbenchMCP.rawValue)
    }

    func testPresentationExposesHandoffAndGateFlags() {
        let handoff = FirstRunBootstrapPresentation(mode: .agentDriven, rows: [], headline: "h")
        XCTAssertTrue(handoff.didHandOff)
        XCTAssertFalse(handoff.opensProviderGate)

        let parked = FirstRunBootstrapPresentation(mode: .parkedAwaitingProvider, rows: [], headline: "h")
        XCTAssertFalse(parked.didHandOff)
        XCTAssertTrue(parked.opensProviderGate)
    }

    func testEveryStateRowHasRawAuditDetail() {
        let states: [BootstrapStepRunState] = [.pending, .active, .verified, .halted, .awaitingHuman, .skipped]
        for state in states {
            let row = BootstrapStepProgress(step: .ensureDaemon, state: state)
            XCTAssertFalse(row.auditDetail.isEmpty, "state \(state) produced empty audit detail")
        }
    }

    // MARK: - FirstRunMode from a BootstrapPhase

    func testHandedOffPhaseDrivesAgentDrivenMode() {
        XCTAssertEqual(FirstRunMode(phase: .handedOff), .agentDriven)
    }

    func testParkedPhaseDrivesParkedMode() {
        XCTAssertEqual(FirstRunMode(phase: .parkedAwaitingProviderConfig), .parkedAwaitingProvider)
    }

    func testAwaitingHandoffPhaseStaysBootstrapping() {
        XCTAssertEqual(FirstRunMode(phase: .awaitingHandoff), .bootstrapping)
    }

    func testFailedStepPhaseDrivesNeedsAttentionMode() {
        XCTAssertEqual(FirstRunMode(phase: .failedStep(.verifyCredentials)), .needsAttention)
    }

    func testFailedInvalidAgentDrivesNeedsAttentionMode() {
        XCTAssertEqual(FirstRunMode(phase: .failedInvalidAgent), .needsAttention)
    }

    func testAgentDrivenIsTheOnlyModeThatHandedOff() {
        XCTAssertTrue(FirstRunMode.agentDriven.didHandOff)
        XCTAssertFalse(FirstRunMode.bootstrapping.didHandOff)
        XCTAssertFalse(FirstRunMode.parkedAwaitingProvider.didHandOff)
        XCTAssertFalse(FirstRunMode.needsAttention.didHandOff)
    }

    func testOnlyParkedModeOpensTheProviderGate() {
        XCTAssertTrue(FirstRunMode.parkedAwaitingProvider.opensProviderGate)
        XCTAssertFalse(FirstRunMode.bootstrapping.opensProviderGate)
        XCTAssertFalse(FirstRunMode.agentDriven.opensProviderGate)
        XCTAssertFalse(FirstRunMode.needsAttention.opensProviderGate)
    }

    func testEveryModeHasASeamFreeHeadline() {
        for mode in FirstRunMode.allCases {
            assertNoCliSeam(mode.headline)
            XCTAssertFalse(mode.headline.isEmpty)
        }
    }

    // MARK: - The drive presenter: rows from a result

    /// All six steps verified, then handed off: every row is `verified`, mode is agent-driven.
    func testPresentsAllVerifiedRowsOnHandoff() {
        let result = BootstrapResult(
            phase: .handedOff,
            stepOutcomes: BootstrapStep.allCases.map { BootstrapStepOutcome(step: $0, recovery: .verified) }
        )
        let drive = FirstRunBootstrapDrive()
        let presentation = drive.present(result: result, activeStep: nil)

        XCTAssertEqual(presentation.mode, .agentDriven)
        XCTAssertEqual(presentation.rows.count, BootstrapStep.allCases.count)
        XCTAssertTrue(presentation.rows.allSatisfy { $0.isDone })
        assertNoCliSeam(presentation.headline)
    }

    /// Mid-run: S0/S1 verified, S2 active. Remaining steps are pending. Mode stays bootstrapping.
    func testPresentsActiveAndPendingRowsMidRun() {
        let result = BootstrapResult(
            phase: .awaitingHandoff,
            stepOutcomes: [
                BootstrapStepOutcome(step: .ensureDaemon, recovery: .verified),
                BootstrapStepOutcome(step: .ensureAgentExists, recovery: .verified),
            ]
        )
        let drive = FirstRunBootstrapDrive()
        let presentation = drive.present(result: result, activeStep: .providerConfig)

        XCTAssertEqual(presentation.mode, .bootstrapping)
        // Verified rows first.
        XCTAssertEqual(presentation.rows[0].state, .verified)
        XCTAssertEqual(presentation.rows[1].state, .verified)
        // The active step row is active.
        let providerRow = presentation.rows.first { $0.step == .providerConfig }
        XCTAssertEqual(providerRow?.state, .active)
        // Steps after the active one are pending.
        let vaultRow = presentation.rows.first { $0.step == .vaultSync }
        XCTAssertEqual(vaultRow?.state, .pending)
    }

    /// Parked at S2: the steps before S2 are verified; S2 is awaiting the human; the rest pending.
    func testPresentsParkedProviderGate() {
        let result = BootstrapResult(
            phase: .parkedAwaitingProviderConfig,
            stepOutcomes: [
                BootstrapStepOutcome(step: .ensureDaemon, recovery: .verified),
                BootstrapStepOutcome(step: .ensureAgentExists, recovery: .verified),
            ]
        )
        let drive = FirstRunBootstrapDrive()
        let presentation = drive.present(result: result, activeStep: nil)

        XCTAssertEqual(presentation.mode, .parkedAwaitingProvider)
        let providerRow = presentation.rows.first { $0.step == .providerConfig }
        XCTAssertEqual(providerRow?.state, .awaitingHuman)
        XCTAssertTrue(presentation.opensProviderGate)
        assertNoCliSeam(presentation.headline)
    }

    /// Halt at a step: that step's row is `halted`; the rest after it are pending; mode needs attention.
    func testPresentsHaltedStep() {
        let result = BootstrapResult(
            phase: .failedStep(.verifyCredentials),
            stepOutcomes: [
                BootstrapStepOutcome(step: .ensureDaemon, recovery: .verified),
                BootstrapStepOutcome(step: .ensureAgentExists, recovery: .verified),
                BootstrapStepOutcome(step: .providerConfig, recovery: .verified),
                BootstrapStepOutcome(step: .vaultSync, recovery: .verified),
                BootstrapStepOutcome(step: .verifyCredentials, recovery: .needsManual),
            ]
        )
        let drive = FirstRunBootstrapDrive()
        let presentation = drive.present(result: result, activeStep: nil)

        XCTAssertEqual(presentation.mode, .needsAttention)
        let failedRow = presentation.rows.first { $0.step == .verifyCredentials }
        XCTAssertEqual(failedRow?.state, .halted)
        XCTAssertTrue(failedRow?.isTerminalFailure ?? false)
        // The step after the failure never ran → pending.
        let mcpRow = presentation.rows.first { $0.step == .registerWorkbenchMCP }
        XCTAssertEqual(mcpRow?.state, .pending)
        assertNoCliSeam(presentation.headline)
    }

    /// Invalid agent: no step ran. All rows pending, mode needs attention, headline honest+seam-free.
    func testPresentsInvalidAgentWithNoStepsRun() {
        let result = BootstrapResult(phase: .failedInvalidAgent, stepOutcomes: [])
        let drive = FirstRunBootstrapDrive()
        let presentation = drive.present(result: result, activeStep: nil)

        XCTAssertEqual(presentation.mode, .needsAttention)
        XCTAssertTrue(presentation.rows.allSatisfy { $0.state == .pending })
        assertNoCliSeam(presentation.headline)
    }

    /// Idle (no run yet): all rows pending, mode bootstrapping, seam-free headline.
    func testPresentsIdleBeforeAnyRun() {
        let drive = FirstRunBootstrapDrive()
        let presentation = drive.presentIdle()

        XCTAssertEqual(presentation.mode, .bootstrapping)
        XCTAssertEqual(presentation.rows.count, BootstrapStep.allCases.count)
        XCTAssertTrue(presentation.rows.allSatisfy { $0.state == .pending })
        assertNoCliSeam(presentation.headline)
    }

    /// Rows are always in canonical S0→S5 order regardless of the outcomes' order.
    func testRowsAreInCanonicalStepOrder() {
        let result = BootstrapResult(
            phase: .awaitingHandoff,
            stepOutcomes: [
                BootstrapStepOutcome(step: .registerWorkbenchMCP, recovery: .verified),
                BootstrapStepOutcome(step: .ensureDaemon, recovery: .verified),
            ]
        )
        let drive = FirstRunBootstrapDrive()
        let presentation = drive.present(result: result, activeStep: nil)
        XCTAssertEqual(presentation.rows.map(\.step), BootstrapStep.allCases)
    }

    // MARK: - shouldStart gating (run/skip decision)

    func testShouldStartWhenFreshWithResolvedBossAndNotRunning() {
        XCTAssertTrue(FirstRunBootstrapDrive.shouldStart(
            isReady: false, hasResolvedBoss: true, isRunning: false, currentMode: nil))
    }

    func testShouldNotStartWhenAlreadyReady() {
        XCTAssertFalse(FirstRunBootstrapDrive.shouldStart(
            isReady: true, hasResolvedBoss: true, isRunning: false, currentMode: nil))
    }

    func testShouldNotStartWithoutAResolvedBoss() {
        XCTAssertFalse(FirstRunBootstrapDrive.shouldStart(
            isReady: false, hasResolvedBoss: false, isRunning: false, currentMode: nil))
    }

    func testShouldNotStartWhileAlreadyRunning() {
        XCTAssertFalse(FirstRunBootstrapDrive.shouldStart(
            isReady: false, hasResolvedBoss: true, isRunning: true, currentMode: nil))
    }

    func testShouldNotRestartOnceAgentDriven() {
        // After handoff the agent drives — never re-enter Layer A from an onAppear.
        XCTAssertFalse(FirstRunBootstrapDrive.shouldStart(
            isReady: false, hasResolvedBoss: true, isRunning: false, currentMode: .agentDriven))
    }

    func testShouldRestartWhenParkedSoAReappearReRunsThePostFormProbe() {
        // Parked is re-runnable: after the human submits the form, a re-run crosses the gate.
        XCTAssertTrue(FirstRunBootstrapDrive.shouldStart(
            isReady: false, hasResolvedBoss: true, isRunning: false, currentMode: .parkedAwaitingProvider))
    }

    func testShouldRestartWhenNeedsAttention() {
        XCTAssertTrue(FirstRunBootstrapDrive.shouldStart(
            isReady: false, hasResolvedBoss: true, isRunning: false, currentMode: .needsAttention))
    }

    // MARK: - Agent-driven (Layer B) narration framing

    func testAgentDrivenHandoffNarrationIsSeamFreeAndInvitesInspection() {
        // The instant Layer A hands off, the UI prompts the boss to inspect+remediate+narrate.
        // That handoff narration line is product copy → seam-free.
        let line = FirstRunBootstrapDrive.agentDrivenHandoffNarration
        assertNoCliSeam(line)
        XCTAssertFalse(line.isEmpty)
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
