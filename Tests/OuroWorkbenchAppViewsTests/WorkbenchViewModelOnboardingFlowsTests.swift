#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 3 — the provider-config / vault-onboarding flow handlers (`submitProviderConfig`
/// `:8035`, the `present*` form openers, `completeVaultOnboarding` `:8318`, `beginVaultOnboarding`
/// `:8173`). These are state-transition + form-dispatch logic over the pure Core
/// `ProviderConfigForm` / `VaultOnboardingMachine`; the SYNCHRONOUS arms (form-open flag sets, the
/// submit invalid/unsupported/cold-start-flag arms, the vault-onboarding marker clearing) are
/// directly INVOKE-able + effect-asserted + mutation-verified. The async re-probe Tasks (which spawn
/// a real `ouro check` subprocess) are the genuine-machinery boundary — driven up to the Task.
@MainActor
final class WorkbenchViewModelOnboardingFlowsTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmonbo-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    // MARK: - Form openers (flag-set state transitions)

    func testPresentProviderConfigForm_setsFlagsForExistingAgent() throws {
        let m = try makeVM()
        m.providerConfigNeedsVaultSetup = true   // stale flag that the opener must reset
        m.presentProviderConfigForm(agentName: "alpha")
        XCTAssertTrue(m.isProviderConfigPresented)
        XCTAssertFalse(m.providerConfigIsNewAgent, "existing-agent form")
        XCTAssertFalse(m.providerConfigNeedsVaultSetup, "the opener resets the stale needs-vault flag")
        XCTAssertEqual(m.providerConfigAgentName, "alpha")
    }

    func testPresentProviderConfigForm_emptyName_fallsBackToBoss() throws {
        let m = try makeVM()
        m.presentProviderConfigForm(agentName: "  ")
        XCTAssertEqual(m.providerConfigAgentName, "boss", "blank name → the boss agent")
    }

    func testPresentNewAgentProviderConfigForm_setsNewAgentFlags() throws {
        let m = try makeVM()
        m.presentNewAgentProviderConfigForm()
        XCTAssertTrue(m.isProviderConfigPresented)
        XCTAssertTrue(m.providerConfigIsNewAgent, "new-agent form")
        XCTAssertEqual(m.providerConfigAgentName, "", "new-agent form starts with an empty name")
    }

    func testPresentCloneAgentSheet_presents() throws {
        let m = try makeVM()
        m.presentCloneAgentSheet()
        XCTAssertTrue(m.isOuroAgentInstallSheetPresented)
    }

    // MARK: - submitProviderConfig synchronous arms

    func testSubmit_missingValues_returnsInvalid() throws {
        let m = try makeVM()
        m.providerConfigAgentName = "fresh-agent"
        let msg = m.submitProviderConfig(provider: .anthropic, humanName: "Sam", values: [:])
        XCTAssertNotNil(msg, "missing credential values → an invalid message")
        XCTAssertTrue(msg?.hasPrefix("Please fill in:") == true, "the invalid arm: \(msg ?? "nil")")
    }

    func testSubmit_missingHumanName_returnsInvalid() throws {
        let m = try makeVM()
        m.providerConfigAgentName = "fresh-agent"
        // anthropic's credential present but humanName blank → the humanName invalid arm.
        let fields = WorkbenchProvider.anthropic.credentialFields
        var values: [String: String] = [:]
        for f in fields { values[f.key] = "secret-value" }
        let msg = m.submitProviderConfig(provider: .anthropic, humanName: "   ", values: values)
        XCTAssertTrue(msg?.contains("your name") == true, "blank humanName → name invalid arm: \(msg ?? "nil")")
    }

    func testSubmit_unsupportedColdStartSink_returnsHonestMessage() throws {
        let m = try makeVM()
        m.providerConfigAgentName = "fresh-agent"
        // githubCopilot has no cold-start argv sink → the unsupported-sink arm.
        let fields = WorkbenchProvider.githubCopilot.credentialFields
        var values: [String: String] = [:]
        for f in fields { values[f.key] = "secret-value" }
        let msg = m.submitProviderConfig(provider: .githubCopilot, humanName: "Sam", values: values)
        XCTAssertTrue(msg?.contains("can't be connected automatically yet") == true,
                      "unsupported-sink arm: \(msg ?? "nil")")
    }

    func testSubmit_coldStartHatch_setsInFlightFlag_returnsNil() throws {
        let m = try makeVM()
        m.providerConfigAgentName = "fresh-agent"
        // anthropic supports cold-start → the .coldStartHatch arm: in-flight flag set, nil return
        // (the async hatch Task is the machinery boundary; the synchronous flag-set is driven).
        let fields = WorkbenchProvider.anthropic.credentialFields
        var values: [String: String] = [:]
        for f in fields { values[f.key] = "sk-test-credential" }
        let msg = m.submitProviderConfig(provider: .anthropic, humanName: "Sam", values: values)
        XCTAssertNil(msg, "cold-start path returns nil (hatch in flight, form stays open)")
        XCTAssertTrue(m.providerConfigColdStartInFlight, "cold-start sets the in-flight flag")
        XCTAssertEqual(m.providerConfigInFlightLabel, "Creating your agent…", "cold-start spinner label")
    }

    func testSubmit_existingAgent_routesToRotation_returnsNil() throws {
        let m = try makeVM()
        // Make an agent "exist" so the rotation branch fires (returns nil, begins rotation).
        m.ouroAgents = [OuroAgentRecord(
            name: "boss", bundlePath: "AgentBundles/boss.ouro",
            configPath: "AgentBundles/boss.ouro/agent.json", status: .ready, detail: "ready",
            humanFacing: OuroAgentLane(provider: "anthropic", model: "claude-opus-4"),
            agentFacing: OuroAgentLane(provider: "anthropic", model: "claude-sonnet-4"))]
        m.providerConfigAgentName = "boss"
        let fields = WorkbenchProvider.anthropic.credentialFields
        var values: [String: String] = [:]
        for f in fields { values[f.key] = "sk-rotate" }
        let msg = m.submitProviderConfig(provider: .anthropic, humanName: "Sam", values: values)
        XCTAssertNil(msg, "existing-agent rotation returns nil (in-flight via beginCredentialRotation)")
        XCTAssertTrue(m.providerConfigColdStartInFlight, "rotation sets the in-flight flag")
    }

    // MARK: - validation helpers

    func testProviderConfigAgentAlreadyExists() throws {
        let m = try makeVM()
        m.ouroAgents = [OuroAgentRecord(
            name: "alpha", bundlePath: "AgentBundles/alpha.ouro",
            configPath: "AgentBundles/alpha.ouro/agent.json", status: .ready, detail: "ready",
            humanFacing: OuroAgentLane(provider: "anthropic", model: "m"),
            agentFacing: OuroAgentLane(provider: "anthropic", model: "m"))]
        XCTAssertTrue(m.providerConfigAgentAlreadyExists(named: "alpha"))
        XCTAssertTrue(m.providerConfigAgentAlreadyExists(named: "ALPHA"), "case-insensitive")
        XCTAssertFalse(m.providerConfigAgentAlreadyExists(named: "beta"))
    }

    func testNewAgentNameValidationMessage_rejectsCollision() throws {
        let m = try makeVM()
        m.ouroAgents = [OuroAgentRecord(
            name: "taken", bundlePath: "AgentBundles/taken.ouro",
            configPath: "AgentBundles/taken.ouro/agent.json", status: .ready, detail: "ready",
            humanFacing: OuroAgentLane(provider: "anthropic", model: "m"),
            agentFacing: OuroAgentLane(provider: "anthropic", model: "m"))]
        XCTAssertNotNil(m.newAgentNameValidationMessage("taken"), "a collision name is rejected")
        XCTAssertNil(m.newAgentNameValidationMessage("brand-new-unique-name"), "a fresh name is valid")
    }

    // MARK: - completeVaultOnboarding synchronous effect

    func testCompleteVaultOnboarding_setsInFlightForAsyncClassify() throws {
        let m = try makeVM()
        m.providerConfigAgentName = "alpha"
        m.completeVaultOnboarding(vaultExitCode: 1)   // non-zero → no re-probe subprocess spawned
        // The synchronous part clears the in-flight markers (private) and sets the cold-start
        // in-flight flag for the async classification Task — assert the public observable effect.
        XCTAssertTrue(m.providerConfigColdStartInFlight,
                      "completeVaultOnboarding sets the in-flight flag for the async classify")
    }

    // MARK: - Negative control (mutation-verified)

    func testNegativeControl_presentNewAgentFormSetsNewAgentFlag() throws {
        // presentNewAgentProviderConfigForm → providerConfigIsNewAgent = true. A no-op would leave
        // it false (the presentProviderConfigForm default) → RED.
        let m = try makeVM()
        m.providerConfigIsNewAgent = false
        m.presentNewAgentProviderConfigForm()
        XCTAssertTrue(m.providerConfigIsNewAgent, "the new-agent opener sets the new-agent flag")
    }
}
#endif
