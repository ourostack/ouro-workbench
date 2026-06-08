import XCTest
@testable import OuroWorkbenchCore

/// Unit 4.3 — the pure decision logic that resolves the REAL bootstrap step inputs from already-
/// scanned app state (agent inventory + MCP registration). The closures the app injects into
/// `BootstrapStepEffects` are thin wrappers over these pure resolvers, so the branching
/// (does-a-usable-agent-exist, are-creds-present, gate status) unit-tests without a live daemon.
final class FirstRunBootstrapEffectsResolverTests: XCTestCase {

    private func agent(
        name: String,
        status: OuroAgentBundleStatus = .ready,
        humanProvider: String? = nil,
        agentProvider: String? = nil
    ) -> OuroAgentRecord {
        OuroAgentRecord(
            name: name,
            bundlePath: "/tmp/\(name).ouro",
            configPath: "/tmp/\(name).ouro/agent.json",
            status: status,
            detail: "detail",
            humanFacing: humanProvider.map { OuroAgentLane(provider: $0, model: "m") },
            agentFacing: agentProvider.map { OuroAgentLane(provider: $0, model: "m") }
        )
    }

    // MARK: - S1 existing-agent detection

    func testAgentExistsWhenAUsableBundleWithThatNameIsPresent() {
        let agents = [agent(name: "ouroboros"), agent(name: "slugger")]
        XCTAssertTrue(FirstRunBootstrapEffectsResolver.usableAgentExists(named: "ouroboros", in: agents))
    }

    func testAgentExistsIsCaseInsensitive() {
        let agents = [agent(name: "Ouroboros")]
        XCTAssertTrue(FirstRunBootstrapEffectsResolver.usableAgentExists(named: "ouroboros", in: agents))
    }

    func testAgentDoesNotExistWhenAbsent() {
        let agents = [agent(name: "slugger")]
        XCTAssertFalse(FirstRunBootstrapEffectsResolver.usableAgentExists(named: "ouroboros", in: agents))
    }

    func testAgentDoesNotExistWhenPresentButNotReady() {
        let agents = [agent(name: "ouroboros", status: .missingConfig)]
        XCTAssertFalse(FirstRunBootstrapEffectsResolver.usableAgentExists(named: "ouroboros", in: agents))
    }

    func testAgentDoesNotExistForEmptyName() {
        let agents = [agent(name: "ouroboros")]
        XCTAssertFalse(FirstRunBootstrapEffectsResolver.usableAgentExists(named: "  ", in: agents))
    }

    // MARK: - S2 provider gate status

    func testGateAdvancesWhenUsableAgentHasAProviderLane() {
        let agents = [agent(name: "ouroboros", humanProvider: "anthropic")]
        XCTAssertEqual(
            FirstRunBootstrapEffectsResolver.providerGateStatus(named: "ouroboros", in: agents),
            .credentialsPresent
        )
    }

    func testGateAdvancesWhenOnlyTheInnerLaneHasAProvider() {
        let agents = [agent(name: "ouroboros", agentProvider: "openai")]
        XCTAssertEqual(
            FirstRunBootstrapEffectsResolver.providerGateStatus(named: "ouroboros", in: agents),
            .credentialsPresent
        )
    }

    func testGateIsAbsentWhenAgentExistsButHasNoProviderLane() {
        let agents = [agent(name: "ouroboros")]
        XCTAssertEqual(
            FirstRunBootstrapEffectsResolver.providerGateStatus(named: "ouroboros", in: agents),
            .absent
        )
    }

    func testGateIsAbsentWhenNoAgentExistsYet() {
        // Cold start: no bundle yet → creds are absent → the run parks at the gate (the form
        // is the cold-start hatch sink that creates the agent WITH creds).
        XCTAssertEqual(
            FirstRunBootstrapEffectsResolver.providerGateStatus(named: "ouroboros", in: []),
            .absent
        )
    }

    func testGateAdvanceIsTrueOnlyForCredentialsPresent() {
        XCTAssertTrue(ProviderCredentialStatus.credentialsPresent.advances)
        XCTAssertFalse(ProviderCredentialStatus.absent.advances)
        XCTAssertFalse(ProviderCredentialStatus.declined.advances)
    }

    // MARK: - S1 verify health (cold-start defers agent creation to the gate)

    func testS1VerifyIsHealthyWhenAgentAlreadyExists() {
        let agents = [agent(name: "ouroboros")]
        XCTAssertEqual(
            FirstRunBootstrapEffectsResolver.ensureAgentExistsHealth(named: "ouroboros", in: agents),
            .healthy
        )
    }

    func testS1VerifyDefersHealthyWhenNoAgentSoTheRunReachesTheGate() {
        // S1 cannot hatch pre-gate (no credential yet). It must NOT halt before S2 — the gate is
        // where the cold-start agent is actually created. So with no agent, S1 reads `.healthy`
        // and the machine then PARKS at the (absent-creds) gate — the honest "not created yet"
        // signal lives in the gate's park, not a false S1 success that claims the agent is ready.
        XCTAssertEqual(
            FirstRunBootstrapEffectsResolver.ensureAgentExistsHealth(named: "ouroboros", in: []),
            .healthy
        )
    }

    // MARK: - MCP-registration health resolution

    func testRegistrationHealthIsHealthyWhenRegistered() {
        XCTAssertEqual(
            FirstRunBootstrapEffectsResolver.registrationHealth(.registered),
            .healthy
        )
    }

    func testRegistrationHealthIsStillDegradedOtherwise() {
        XCTAssertEqual(FirstRunBootstrapEffectsResolver.registrationHealth(.notRegistered), .stillDegraded)
        XCTAssertEqual(FirstRunBootstrapEffectsResolver.registrationHealth(.needsUpdate), .stillDegraded)
    }
}
