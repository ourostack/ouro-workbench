import XCTest
@testable import OuroWorkbenchCore

final class AgentReadinessBootstrapTests: XCTestCase {

    // MARK: - Helpers

    /// A context with a valid, explicitly-resolved boss agent name.
    private func validContext(agentName: String = "ouroboros") -> BootstrapAgentContext {
        BootstrapAgentContext(agentName: agentName, humanName: "ari", provider: "anthropic")
    }

    /// Build effects where every step verifies as healthy and creds are present, so the
    /// machine should run straight S0→S5 and then hand off on the first status round-trip.
    private func happyEffects(
        statusReachable: Bool = true,
        recorder: StepRecorder = StepRecorder()
    ) -> BootstrapStepEffects {
        BootstrapStepEffects(
            ensureDaemon: { recorder.record(.ensureDaemon); return .healthy },
            ensureAgentExists: { _ in recorder.record(.ensureAgentExists); return .healthy },
            providerConfig: { recorder.record(.providerConfig); return .credentialsPresent },
            vaultSync: { _ in recorder.record(.vaultSync); return .healthy },
            verifyCredentials: { _ in recorder.record(.verifyCredentials); return .healthy },
            registerWorkbenchMCP: { _ in recorder.record(.registerWorkbenchMCP); return .healthy },
            statusPing: { _ in recorder.record(.statusPing); return statusReachable }
        )
    }

    // MARK: - Full S0→S5 transition + handoff

    func testRunsAllStepsInOrderThenHandsOff() async {
        let recorder = StepRecorder()
        let bootstrap = AgentReadinessBootstrap(
            context: validContext(),
            effects: happyEffects(recorder: recorder)
        )

        let result = await bootstrap.run()

        XCTAssertEqual(result.phase, .handedOff)
        XCTAssertEqual(
            recorder.steps,
            [.ensureDaemon, .ensureAgentExists, .providerConfig, .vaultSync,
             .verifyCredentials, .registerWorkbenchMCP, .statusPing]
        )
        // Every executed step recorded a recovery-truth classification.
        XCTAssertEqual(result.stepOutcomes.count, 6)
        XCTAssertTrue(result.stepOutcomes.allSatisfy { $0.recovery == .verified })
    }

    func testEachStepIsReportedHealthyAndAdvances() async {
        let bootstrap = AgentReadinessBootstrap(context: validContext(), effects: happyEffects())
        let result = await bootstrap.run()

        let reachedSteps = result.stepOutcomes.map(\.step)
        XCTAssertEqual(
            reachedSteps,
            [.ensureDaemon, .ensureAgentExists, .providerConfig, .vaultSync,
             .verifyCredentials, .registerWorkbenchMCP]
        )
    }

    // MARK: - S2 declined-provider PARK (no busy-loop, no advance)

    func testDeclinedProviderParksAndDoesNotAdvance() async {
        let recorder = StepRecorder()
        var effects = happyEffects(recorder: recorder)
        effects.providerConfig = { recorder.record(.providerConfig); return .declined }

        let bootstrap = AgentReadinessBootstrap(context: validContext(), effects: effects)
        let result = await bootstrap.run()

        XCTAssertEqual(result.phase, .parkedAwaitingProviderConfig)
        // Parked is a stable, terminal-ish state: nothing past S2 ran.
        XCTAssertFalse(recorder.steps.contains(.vaultSync))
        XCTAssertFalse(recorder.steps.contains(.verifyCredentials))
        XCTAssertFalse(recorder.steps.contains(.registerWorkbenchMCP))
        XCTAssertFalse(recorder.steps.contains(.statusPing))
    }

    func testAbsentCredentialsParksAndDoesNotAdvance() async {
        let recorder = StepRecorder()
        var effects = happyEffects(recorder: recorder)
        effects.providerConfig = { recorder.record(.providerConfig); return .absent }

        let bootstrap = AgentReadinessBootstrap(context: validContext(), effects: effects)
        let result = await bootstrap.run()

        XCTAssertEqual(result.phase, .parkedAwaitingProviderConfig)
        XCTAssertFalse(recorder.steps.contains(.vaultSync))
    }

    func testParkDoesNotBusyLoopProviderConfig() async {
        let recorder = StepRecorder()
        var effects = happyEffects(recorder: recorder)
        effects.providerConfig = { recorder.record(.providerConfig); return .declined }

        let bootstrap = AgentReadinessBootstrap(context: validContext(), effects: effects)
        let result = await bootstrap.run()

        // Parked must be reached by exactly ONE provider-config attempt — never re-polled.
        let providerAttempts = recorder.steps.filter { $0 == .providerConfig }.count
        XCTAssertEqual(providerAttempts, 1, "Parking must not busy-loop the provider gate.")
        XCTAssertEqual(result.phase, .parkedAwaitingProviderConfig)
    }

    func testRunningAParkedMachineAgainDoesNotReAttemptUntilCredsSupplied() async {
        // Re-running the same parked machine (still declined) must remain parked with no
        // additional provider re-attempt churn beyond the single gate check.
        let recorder = StepRecorder()
        var effects = happyEffects(recorder: recorder)
        effects.providerConfig = { recorder.record(.providerConfig); return .declined }

        let bootstrap = AgentReadinessBootstrap(context: validContext(), effects: effects)
        _ = await bootstrap.run()
        let result = await bootstrap.run()

        XCTAssertEqual(result.phase, .parkedAwaitingProviderConfig)
        // Two runs → two single gate checks, never a tight loop within a run.
        XCTAssertEqual(recorder.steps.filter { $0 == .providerConfig }.count, 2)
    }

    func testParkExitsOnceCredentialsSupplied() async {
        // The ONLY exit from park is the human supplying creds: a later run whose
        // provider-config now reports present must advance past S2.
        let recorder = StepRecorder()
        let supplied = Flag()
        var effects = happyEffects(recorder: recorder)
        effects.providerConfig = {
            recorder.record(.providerConfig)
            return supplied.value ? .credentialsPresent : .declined
        }

        let bootstrap = AgentReadinessBootstrap(context: validContext(), effects: effects)
        let parked = await bootstrap.run()
        XCTAssertEqual(parked.phase, .parkedAwaitingProviderConfig)

        supplied.set(true)
        let advanced = await bootstrap.run()
        XCTAssertEqual(advanced.phase, .handedOff)
    }

    // MARK: - Wrong-agent guard (explicit resolved name required)

    func testEmptyAgentNameFailsBeforeRunningAnyStep() async {
        let recorder = StepRecorder()
        let bootstrap = AgentReadinessBootstrap(
            context: BootstrapAgentContext(agentName: "", humanName: "ari", provider: "anthropic"),
            effects: happyEffects(recorder: recorder)
        )

        let result = await bootstrap.run()

        XCTAssertEqual(result.phase, .failedInvalidAgent)
        XCTAssertTrue(recorder.steps.isEmpty, "No step may target an unresolved agent name.")
    }

    func testPathSeparatorAgentNameFailsGuard() async {
        let bootstrap = AgentReadinessBootstrap(
            context: BootstrapAgentContext(agentName: "ouro/boss", humanName: "ari", provider: "anthropic"),
            effects: happyEffects()
        )
        let result = await bootstrap.run()
        XCTAssertEqual(result.phase, .failedInvalidAgent)
    }

    func testEveryAgentTargetedStepReceivesTheExplicitResolvedName() async {
        let seenNames = NameRecorder()
        var effects = happyEffects()
        effects.ensureAgentExists = { name in seenNames.record(name); return .healthy }
        effects.vaultSync = { name in seenNames.record(name); return .healthy }
        effects.verifyCredentials = { name in seenNames.record(name); return .healthy }
        effects.registerWorkbenchMCP = { name in seenNames.record(name); return .healthy }
        effects.statusPing = { name in seenNames.record(name); return true }

        let bootstrap = AgentReadinessBootstrap(context: validContext(agentName: "slugger"), effects: effects)
        _ = await bootstrap.run()

        // Every agent-targeted step got the explicit resolved name — never an implicit default.
        XCTAssertEqual(seenNames.names, ["slugger", "slugger", "slugger", "slugger", "slugger"])
        XCTAssertTrue(seenNames.names.allSatisfy { $0 == "slugger" })
    }

    // MARK: - Handoff fires ONLY on status success

    func testHandoffDoesNotFireWhenStatusPingFails() async {
        let recorder = StepRecorder()
        let bootstrap = AgentReadinessBootstrap(
            context: validContext(),
            effects: happyEffects(statusReachable: false, recorder: recorder)
        )

        let result = await bootstrap.run()

        // All steps ran, but the status round-trip failed → still Layer A, not handed off.
        XCTAssertTrue(recorder.steps.contains(.statusPing))
        XCTAssertEqual(result.phase, .awaitingHandoff)
        XCTAssertNotEqual(result.phase, .handedOff)
    }

    func testHandoffFiresOnlyOnFirstSuccessfulStatusRoundTrip() async {
        let bootstrap = AgentReadinessBootstrap(
            context: validContext(),
            effects: happyEffects(statusReachable: true)
        )
        let result = await bootstrap.run()
        XCTAssertEqual(result.phase, .handedOff)
        XCTAssertTrue(result.didHandOff)
    }

    // MARK: - Recovery-truth classification per step (never assume success)

    func testStepReportingStillDegradedClassifiesRecoveryNotVerified() async {
        // S0 daemon still down after ensure → recovery-truth must be `stillDegraded`,
        // the machine must NOT pretend success and must NOT advance.
        let recorder = StepRecorder()
        var effects = happyEffects(recorder: recorder)
        effects.ensureDaemon = { recorder.record(.ensureDaemon); return .stillDegraded }

        let bootstrap = AgentReadinessBootstrap(context: validContext(), effects: effects)
        let result = await bootstrap.run()

        XCTAssertEqual(result.phase, .failedStep(.ensureDaemon))
        XCTAssertEqual(result.stepOutcomes.last?.step, .ensureDaemon)
        XCTAssertEqual(result.stepOutcomes.last?.recovery, .stillDegraded)
        // No subsequent step ran.
        XCTAssertFalse(recorder.steps.contains(.ensureAgentExists))
    }

    func testStepReportingNeedsManualClassifiesRecoveryAndHalts() async {
        let recorder = StepRecorder()
        var effects = happyEffects(recorder: recorder)
        effects.verifyCredentials = { _ in recorder.record(.verifyCredentials); return .needsManual }

        let bootstrap = AgentReadinessBootstrap(context: validContext(), effects: effects)
        let result = await bootstrap.run()

        XCTAssertEqual(result.phase, .failedStep(.verifyCredentials))
        XCTAssertEqual(result.stepOutcomes.last?.recovery, .needsManual)
        XCTAssertFalse(recorder.steps.contains(.registerWorkbenchMCP))
    }

    func testStepReportingStillDegradedAtS1HaltsBeforeProviderGate() async {
        // S1 (ensure-agent-exists) failing must halt before the S2 provider gate is reached.
        let recorder = StepRecorder()
        var effects = happyEffects(recorder: recorder)
        effects.ensureAgentExists = { _ in recorder.record(.ensureAgentExists); return .stillDegraded }

        let bootstrap = AgentReadinessBootstrap(context: validContext(), effects: effects)
        let result = await bootstrap.run()

        XCTAssertEqual(result.phase, .failedStep(.ensureAgentExists))
        XCTAssertFalse(recorder.steps.contains(.providerConfig))
    }

    func testStepReportingStillDegradedAtS3HaltsAfterGate() async {
        // S3 (vault sync) failing halts after the gate cleared but before S4/S5.
        let recorder = StepRecorder()
        var effects = happyEffects(recorder: recorder)
        effects.vaultSync = { _ in recorder.record(.vaultSync); return .stillDegraded }

        let bootstrap = AgentReadinessBootstrap(context: validContext(), effects: effects)
        let result = await bootstrap.run()

        XCTAssertEqual(result.phase, .failedStep(.vaultSync))
        XCTAssertTrue(recorder.steps.contains(.providerConfig))
        XCTAssertFalse(recorder.steps.contains(.verifyCredentials))
    }

    func testStepReportingStillDegradedAtS5HaltsBeforeHandoff() async {
        // S5 (register Workbench MCP) failing halts before the handoff status ping.
        let recorder = StepRecorder()
        var effects = happyEffects(recorder: recorder)
        effects.registerWorkbenchMCP = { _ in recorder.record(.registerWorkbenchMCP); return .stillDegraded }

        let bootstrap = AgentReadinessBootstrap(context: validContext(), effects: effects)
        let result = await bootstrap.run()

        XCTAssertEqual(result.phase, .failedStep(.registerWorkbenchMCP))
        XCTAssertFalse(recorder.steps.contains(.statusPing))
    }

    func testRecoveryTruthIsDerivedFromPostEffectVerifyNotAssumedSuccess() async {
        // Map each StepHealth → recovery-truth classification directly.
        XCTAssertEqual(BootstrapRecoveryTruth.classify(.healthy), .verified)
        XCTAssertEqual(BootstrapRecoveryTruth.classify(.stillDegraded), .stillDegraded)
        XCTAssertEqual(BootstrapRecoveryTruth.classify(.needsManual), .needsManual)
    }

    func testVerifiedRecoveryAdvancesOthersHalt() {
        XCTAssertTrue(BootstrapRecoveryTruth.verified.didVerify)
        XCTAssertFalse(BootstrapRecoveryTruth.stillDegraded.didVerify)
        XCTAssertFalse(BootstrapRecoveryTruth.needsManual.didVerify)
    }

    // MARK: - S1 command construction (headless hatch / clone)

    func testBuildsHeadlessHatchCommandWithExplicitAgentNameAndCredFlags() throws {
        let plan = try BootstrapAgentProvisionCommand.hatch(
            agentName: "ouroboros",
            humanName: "ari",
            provider: "anthropic",
            credential: .apiKey("sk-test")
        )

        // Explicit agent name (never an implicit default), headless flags, cred flag present.
        XCTAssertTrue(plan.tokens.contains("hatch"))
        XCTAssertEqual(adjacentValue(in: plan.tokens, after: "--agent"), "ouroboros")
        XCTAssertEqual(adjacentValue(in: plan.tokens, after: "--human"), "ari")
        XCTAssertEqual(adjacentValue(in: plan.tokens, after: "--provider"), "anthropic")
        XCTAssertEqual(adjacentValue(in: plan.tokens, after: "--api-key"), "sk-test")
        XCTAssertFalse(plan.commandLine.isEmpty)
    }

    func testHatchSupportsEachCredentialFlavor() throws {
        let setup = try BootstrapAgentProvisionCommand.hatch(
            agentName: "a", humanName: "h", provider: "p", credential: .setupToken("st"))
        XCTAssertEqual(adjacentValue(in: setup.tokens, after: "--setup-token"), "st")

        let oauth = try BootstrapAgentProvisionCommand.hatch(
            agentName: "a", humanName: "h", provider: "p", credential: .oauthToken("ot"))
        XCTAssertEqual(adjacentValue(in: oauth.tokens, after: "--oauth-token"), "ot")

        let endpoint = try BootstrapAgentProvisionCommand.hatch(
            agentName: "a", humanName: "h", provider: "p",
            credential: .endpoint(endpoint: "https://e", deployment: "d"))
        XCTAssertEqual(adjacentValue(in: endpoint.tokens, after: "--endpoint"), "https://e")
        XCTAssertEqual(adjacentValue(in: endpoint.tokens, after: "--deployment"), "d")
    }

    func testHatchRejectsInvalidAgentName() {
        XCTAssertThrowsError(try BootstrapAgentProvisionCommand.hatch(
            agentName: "bad/name", humanName: "h", provider: "p", credential: .apiKey("k")))
        XCTAssertThrowsError(try BootstrapAgentProvisionCommand.hatch(
            agentName: "", humanName: "h", provider: "p", credential: .apiKey("k")))
    }

    func testHatchRejectsEmptyHumanOrProvider() {
        XCTAssertThrowsError(try BootstrapAgentProvisionCommand.hatch(
            agentName: "a", humanName: "  ", provider: "p", credential: .apiKey("k")))
        XCTAssertThrowsError(try BootstrapAgentProvisionCommand.hatch(
            agentName: "a", humanName: "h", provider: "", credential: .apiKey("k")))
    }

    func testBuildsCloneCommandFromRemote() throws {
        let plan = try BootstrapAgentProvisionCommand.clone(remote: "git@example.com:agent.git")
        XCTAssertTrue(plan.tokens.contains("clone"))
        XCTAssertTrue(plan.tokens.contains("git@example.com:agent.git"))
    }

    func testCloneRejectsEmptyRemote() {
        XCTAssertThrowsError(try BootstrapAgentProvisionCommand.clone(remote: "   "))
    }

    // MARK: - S1 executor injection (does NOT actually run hatch)

    func testEnsureAgentExistsUsesInjectedExecutorAndClassifiesFromVerify() async {
        // The S1 effect both BUILDS a command and runs it through an injected executor;
        // recovery-truth still comes from the post-effect verify, never the executor's exit.
        let ran = Flag()
        let effect = BootstrapAgentExistsEffect(
            existingAgentIsUsable: { false },
            provisionCommand: { try BootstrapAgentProvisionCommand.hatch(
                agentName: "ouroboros", humanName: "ari", provider: "anthropic",
                credential: .apiKey("k")) },
            execute: { _ in ran.set(true) },          // injected — does not actually run hatch
            verify: { _ in .healthy }                 // post-effect verify is the source of truth
        )

        let health = await effect.run(agentName: "ouroboros")
        XCTAssertTrue(ran.value)
        XCTAssertEqual(health, .healthy)
    }

    func testEnsureAgentExistsSkipsProvisionWhenUsableAgentAlreadyExists() async {
        let ran = Flag()
        let effect = BootstrapAgentExistsEffect(
            existingAgentIsUsable: { true },           // already usable → no hatch/clone
            provisionCommand: { try BootstrapAgentProvisionCommand.hatch(
                agentName: "ouroboros", humanName: "ari", provider: "anthropic",
                credential: .apiKey("k")) },
            execute: { _ in ran.set(true) },
            verify: { _ in .healthy }
        )

        let health = await effect.run(agentName: "ouroboros")
        XCTAssertFalse(ran.value, "A usable agent bundle must not trigger hatch/clone.")
        XCTAssertEqual(health, .healthy)
    }

    func testEnsureAgentExistsReportsStillDegradedWhenVerifyFailsAfterProvision() async {
        let effect = BootstrapAgentExistsEffect(
            existingAgentIsUsable: { false },
            provisionCommand: { try BootstrapAgentProvisionCommand.hatch(
                agentName: "ouroboros", humanName: "ari", provider: "anthropic",
                credential: .apiKey("k")) },
            execute: { _ in },
            verify: { _ in .stillDegraded }            // verify still failing → honest classification
        )

        let health = await effect.run(agentName: "ouroboros")
        XCTAssertEqual(health, .stillDegraded)
    }

    func testEnsureAgentExistsReportsNeedsManualWhenProvisionThrows() async {
        // A thrown provision/execute must not crash the step; verify-after-failure is what
        // classifies — a throwing build/exec means the post-verify will read degraded, but
        // the step itself must surface needsManual rather than pretend success.
        let effect = BootstrapAgentExistsEffect(
            existingAgentIsUsable: { false },
            provisionCommand: { throw OuroAgentInstallCommandError.emptyRemote },
            execute: { _ in },
            verify: { _ in .healthy }
        )

        let health = await effect.run(agentName: "ouroboros")
        XCTAssertEqual(health, .needsManual)
    }

    // MARK: - Seam-free product copy on surfaced states

    func testParkedHumanCopyIsSeamFree() {
        let result = BootstrapResult(phase: .parkedAwaitingProviderConfig, stepOutcomes: [])
        let copy = result.humanFacingLine
        assertNoCliSeam(copy)
    }

    func testHandedOffHumanCopyIsSeamFree() {
        let result = BootstrapResult(phase: .handedOff, stepOutcomes: [])
        assertNoCliSeam(result.humanFacingLine)
    }

    func testFailedStepHumanCopyIsSeamFreeAndHonest() {
        let outcome = BootstrapStepOutcome(step: .verifyCredentials, recovery: .needsManual)
        let result = BootstrapResult(phase: .failedStep(.verifyCredentials), stepOutcomes: [outcome])
        let copy = result.humanFacingLine
        assertNoCliSeam(copy)
        // Honest: it does not claim success.
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("ready to go") )
    }

    func testInvalidAgentHumanCopyIsSeamFree() {
        let result = BootstrapResult(phase: .failedInvalidAgent, stepOutcomes: [])
        assertNoCliSeam(result.humanFacingLine)
    }

    func testAuditDetailMayNameCliVerbs() {
        // Audit lines are the ONE surface where raw `ouro` verbs are allowed.
        let outcome = BootstrapStepOutcome(step: .ensureDaemon, recovery: .stillDegraded)
        XCTAssertFalse(outcome.auditDetail.isEmpty)
    }

    func testAuditDetailCoversEveryRecoveryTruth() {
        let verified = BootstrapStepOutcome(step: .ensureDaemon, recovery: .verified)
        let degraded = BootstrapStepOutcome(step: .vaultSync, recovery: .stillDegraded)
        let manual = BootstrapStepOutcome(step: .verifyCredentials, recovery: .needsManual)
        // Each recovery-truth produces a distinct, non-empty audit line.
        let lines = [verified.auditDetail, degraded.auditDetail, manual.auditDetail]
        XCTAssertEqual(Set(lines).count, 3)
        XCTAssertTrue(lines.allSatisfy { !$0.isEmpty })
        XCTAssertTrue(verified.auditDetail.localizedCaseInsensitiveContains("passed"))
    }

    func testAwaitingHandoffHumanCopyIsSeamFree() {
        let result = BootstrapResult(phase: .awaitingHandoff, stepOutcomes: [])
        assertNoCliSeam(result.humanFacingLine)
        XCTAssertFalse(result.didHandOff)
    }

    func testEachStepHasADistinctAuditLabel() {
        let labels = BootstrapStep.allCases.map(\.auditLabel)
        XCTAssertEqual(Set(labels).count, labels.count)
        XCTAssertFalse(labels.contains(where: \.isEmpty))
    }

    // MARK: - Assertions

    private func assertNoCliSeam(_ value: String, file: StaticString = #filePath, line: UInt = #line) {
        let lowered = value.lowercased()
        XCTAssertFalse(lowered.contains("ouro"), "human copy leaks 'ouro': \(value)", file: file, line: line)
        XCTAssertFalse(lowered.contains("daemon"), "human copy leaks 'daemon': \(value)", file: file, line: line)
        XCTAssertFalse(lowered.contains("hatch"), "human copy leaks 'hatch': \(value)", file: file, line: line)
        XCTAssertFalse(lowered.contains("--"), "human copy leaks a CLI flag: \(value)", file: file, line: line)
    }

    private func adjacentValue(in tokens: [String], after flag: String) -> String? {
        guard let index = tokens.firstIndex(of: flag), index + 1 < tokens.count else {
            return nil
        }
        return tokens[index + 1]
    }
}

// MARK: - Test doubles

private enum RecordedStep: Equatable {
    case ensureDaemon, ensureAgentExists, providerConfig, vaultSync
    case verifyCredentials, registerWorkbenchMCP, statusPing
}

private final class StepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [RecordedStep] = []

    func record(_ step: RecordedStep) {
        lock.lock(); stored.append(step); lock.unlock()
    }

    var steps: [RecordedStep] {
        lock.lock(); defer { lock.unlock() }; return stored
    }
}

private final class NameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func record(_ name: String) {
        lock.lock(); stored.append(name); lock.unlock()
    }

    var names: [String] {
        lock.lock(); defer { lock.unlock() }; return stored
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    func set(_ value: Bool) {
        lock.lock(); stored = value; lock.unlock()
    }

    var value: Bool {
        lock.lock(); defer { lock.unlock() }; return stored
    }
}
