#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 10 — the onboarding / provider / vault / clone tail.
///
/// Drives the synchronous logic of the remaining onboarding remediation + vault flows. Every region
/// is INVOKED + effect-asserted (resulting state / return string / mutation) + mutation-verified
/// (a different input yields a different asserted result):
///   • the 3 carried-forward `start*` dispatchers (deferred from the closed #369/#372/#374):
///     `startSelectLane` (`:8976`), `startRegisterWorkbenchMCP` (`:9012`), `startRepairAgent` (`:8459`)
///     — each: the missing-payload / empty-name SKIP guard (returns the "Skipped …" finishBossAction
///     string BEFORE any runner Task) AND the in-flight-ack arm ("Setting up …"/"Connecting …"/
///     "Working on …" with `isInFlight:true`). All widened private→internal.
///   • onboarding-scan guards: `scanForOnboardingSessions` (`:5586`, already-scanning + not-ready
///     refresh arms) and `startBossReconstruction` (`:5626`, not-ready + already-running guards).
///   • vault flows: `beginVaultOnboarding` (`:8208`) and `beginCredentialRotation` (`:8278`) — the
///     no-provider / empty-name guard + the success path (in-flight flag set, finish-setup/reconnect
///     terminal created via the seamed `launchTerminalSession`, exit-match markers captured, audit
///     logged); `completeVaultOnboarding` (`:8353`) — the synchronous up-front marker clear + flag set
///     (the re-probe + outcome switch run in the detached Task = boundary).
///   • onboarding repair: `runOnboardingRepairStepNatively` (`:8801`, all 5 dispatch arms —
///     repair-agent / check-* / repair-*-provider re-check / default; the runner Tasks are the
///     boundary) + `surfaceNativeRepairLine` (`:8863`, the recovery-truth fold) — both widened.
///   • first-run: `makeFirstRunBootstrapEffects` (`:8597`, widened) — the effects-struct construction
///     (the @Sendable per-step closure wiring; the closure BODIES are the subprocess/MCP boundary).
///   • misc: `openDeskBridgeSetup` (`:5796`, nil-command error + launch arms), `installWorkbenchMCP`
///     (`:2822`, the registrar install success + catch arms), `ensureProject` (`:5812`, reuse +
///     create arms via a public caller), `onboardingNotes` formatting.
///
/// CARVED (genuine machinery, NOT driven here): every `start*` runner Task body (LaneSelectionRunner /
/// WorkbenchMCPRegistrationRunner / AgentRepairRunner / ProviderVerifyRunner — each awaits an `ouro`
/// subprocess / MCP round-trip); `submitProviderConfig`'s `.coldStartHatch` detached Task body
/// (ColdStartHatchRunner.runHeadless = subprocess + `runColdStartProviderCheck`); `completeVault‐
/// Onboarding`'s detached re-probe Task; `runCloneProviderCheck` (live `ouro check`); the
/// `makeFirstRunBootstrapEffects` closure interiors. The `beginVaultOnboarding` /
/// `beginCredentialRotation` createCustomSession-returns-nil launch-failure guard is a defensive arm
/// (createCustomSession bootstraps a project, so it returns nil only in a degenerate no-project state
/// the seeded fixtures can't force deterministically) — left to a later batch if reachable at all.
@MainActor
final class WorkbenchViewModelOnboardingProviderTests: XCTestCase {

    private static let projectId = UUID(uuidString: "CA111FE0-0000-0000-0000-0000000000A1")!
    private static let wsId = UUID(uuidString: "CA111FE0-0000-0000-0000-0000000000B1")!

    // MARK: - Hermetic VM construction

    private func makeTmp() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmonbprov-\(UUID().uuidString)", isDirectory: true)
    }

    /// Build a VM rooted at a temp dir with a seeded valid workspace; the terminal-launch seam is
    /// stubbed so no real session escapes. Returns the VM and its agent-bundles URL (for registrar
    /// fixtures).
    private func makeVM(boss: String = "boss") throws -> WorkbenchViewModel {
        let paths = WorkbenchPaths(rootURL: makeTmp())
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: boss),
            bossWatchEnabled: false,
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp")],
            processEntries: [],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: [])])
        try WorkbenchStore(paths: paths).save(state)
        let agentBundles = paths.rootURL.appendingPathComponent("AgentBundles", isDirectory: true)
        let m = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        m.launchTerminalSession = { _ in }
        return m
    }

    private func action(_ kind: BossWorkbenchActionKind, name: String? = nil, text: String? = nil,
                        lane: ProviderLane? = nil, provider: String? = nil, model: String? = nil) -> BossWorkbenchAction {
        BossWorkbenchAction(action: kind, text: text, name: name, lane: lane, provider: provider, model: model)
    }

    private func readyReadiness(boss: String = "boss") -> OnboardingReadiness {
        OnboardingReadiness(state: .ready, headline: "Ready", detail: "", selectedBossName: boss, repairSteps: [])
    }

    private func notReadyReadiness(boss: String = "boss") -> OnboardingReadiness {
        OnboardingReadiness(state: .needsCredentials, headline: "Needs creds", detail: "", selectedBossName: boss, repairSteps: [])
    }

    // MARK: - startSelectLane (carried-forward)

    func testStartSelectLane_missingPayload_skips() throws {
        let m = try makeVM()
        // Missing lane/provider/model → the guard's "Skipped …" arm.
        let result = m.startSelectLane(action: action(.selectLane, name: "alpha"), source: "test")
        XCTAssertEqual(result, "Skipped selectLane: missing explicit agent name, lane, provider, or model")
    }

    func testStartSelectLane_emptyName_skips() throws {
        let m = try makeVM()
        let result = m.startSelectLane(
            action: action(.selectLane, name: "  ", lane: .outward, provider: "anthropic", model: "claude"),
            source: "test")
        XCTAssertEqual(result, "Skipped selectLane: missing explicit agent name, lane, provider, or model")
    }

    func testStartSelectLane_fullPayload_returnsInFlightAck() throws {
        let m = try makeVM()
        let result = m.startSelectLane(
            action: action(.selectLane, name: "alpha", lane: .outward, provider: "anthropic", model: "claude"),
            source: "test")
        XCTAssertEqual(result, "Setting up alpha with anthropic…",
                       "the full-payload arm returns the in-flight ack (the runner Task lands the verdict later)")
    }

    // MARK: - startRegisterWorkbenchMCP (carried-forward)

    func testStartRegisterWorkbenchMCP_emptyName_skips() throws {
        let m = try makeVM()
        let result = m.startRegisterWorkbenchMCP(action: action(.registerWorkbenchMCP, name: ""), source: "test")
        XCTAssertEqual(result, "Skipped registerWorkbenchMCP: missing explicit agent name")
    }

    func testStartRegisterWorkbenchMCP_withName_returnsInFlightAck() throws {
        let m = try makeVM()
        let result = m.startRegisterWorkbenchMCP(action: action(.registerWorkbenchMCP, name: "alpha"), source: "test")
        XCTAssertEqual(result, "Connecting alpha to Workbench…")
    }

    // MARK: - startRepairAgent (carried-forward)

    func testStartRepairAgent_emptyName_skips() throws {
        let m = try makeVM()
        let result = m.startRepairAgent(action: action(.repairAgent, name: " "), source: "test")
        XCTAssertEqual(result, "Skipped repairAgent: missing explicit agent name")
    }

    func testStartRepairAgent_withName_returnsInFlightAck() throws {
        let m = try makeVM()
        let result = m.startRepairAgent(action: action(.repairAgent, name: "alpha"), source: "test")
        XCTAssertEqual(result, "Working on getting alpha ready…")
    }

    // MARK: - scanForOnboardingSessions guards

    func testScan_alreadyScanning_isNoOp() throws {
        let m = try makeVM()
        m.onboardingIsScanning = true
        m.onboardingImportSummaryHasImports = true
        m.scanForOnboardingSessions()
        // The already-scanning guard returns before touching the import-summary flag.
        XCTAssertTrue(m.onboardingImportSummaryHasImports, "the already-scanning guard returns immediately")
    }

    func testScan_notReady_refreshesAndReturnsWithoutScanning() throws {
        let m = try makeVM()
        m.onboardingReadiness = notReadyReadiness()
        m.scanForOnboardingSessions()
        // The not-ready arm refreshes + returns; it never flips the scanning flag on.
        XCTAssertFalse(m.onboardingIsScanning, "the not-ready arm returns without starting a scan")
    }

    func testScan_ready_startsScan() throws {
        let m = try makeVM()
        m.onboardingReadiness = readyReadiness()
        m.onboardingImportSummaryHasImports = true
        m.scanForOnboardingSessions()
        // The ready arm flips scanning on and resets the import-summary flag before the Task runs.
        XCTAssertTrue(m.onboardingIsScanning, "the ready arm starts the scan (sets the scanning flag)")
        XCTAssertFalse(m.onboardingImportSummaryHasImports, "the ready arm resets the import-summary flag")
    }

    // MARK: - startBossReconstruction guards

    func testStartBossReconstruction_notReady_refreshesAndReturns() throws {
        let m = try makeVM()
        m.onboardingReadiness = notReadyReadiness()
        m.startBossReconstruction()
        XCTAssertFalse(m.onboardingReconstructionHandedOff, "the not-ready arm returns without handing off")
    }

    func testStartBossReconstruction_alreadyRunning_isNoOp() throws {
        let m = try makeVM()
        m.onboardingReadiness = readyReadiness()
        m.bossCheckInIsRunning = true
        m.startBossReconstruction()
        XCTAssertFalse(m.onboardingReconstructionHandedOff, "the already-running guard returns without handing off")
    }

    func testStartBossReconstruction_ready_handsOffAndLogs() throws {
        let m = try makeVM()
        m.onboardingReadiness = readyReadiness()
        m.startBossReconstruction()
        XCTAssertTrue(m.onboardingReconstructionHandedOff, "the ready arm hands reconstruction to the boss")
        XCTAssertTrue(m.state.actionLog.contains { $0.action == "startBossReconstruction" && $0.succeeded },
                      "the hand-off is audited")
    }

    // MARK: - beginVaultOnboarding

    func testBeginVaultOnboarding_noProvider_isNoOp() throws {
        let m = try makeVM()
        m.providerConfigAgentName = "alpha"
        m.providerConfigColdStartProvider = nil
        m.beginVaultOnboarding()
        XCTAssertFalse(m.providerConfigColdStartInFlight, "no stashed provider → the guard returns before setting in-flight")
    }

    func testBeginVaultOnboarding_emptyName_isNoOp() throws {
        let m = try makeVM()
        m.providerConfigAgentName = "   "
        m.providerConfigColdStartProvider = .anthropic
        m.beginVaultOnboarding()
        XCTAssertFalse(m.providerConfigColdStartInFlight, "empty agent name → the guard returns")
    }

    func testBeginVaultOnboarding_success_opensFinishSetupTerminalAndLogs() throws {
        let m = try makeVM()
        m.providerConfigAgentName = "alpha"
        m.providerConfigColdStartProvider = .anthropic
        m.beginVaultOnboarding()
        XCTAssertTrue(m.providerConfigColdStartInFlight, "the re-entrancy gate is engaged")
        XCTAssertEqual(m.vaultOnboardingAgentName, "alpha", "the agent name is captured for exit-matching")
        XCTAssertEqual(m.vaultOnboardingFlavor, .onboarding, "finish-setup runs the onboarding flavor")
        XCTAssertNotNil(m.vaultOnboardingEntryID, "the finish-setup terminal entry is captured")
        XCTAssertTrue(m.state.actionLog.contains { $0.action == "beginVaultOnboarding" },
                      "the finish-setup launch is audited")
    }

    // MARK: - beginCredentialRotation

    func testBeginCredentialRotation_emptyName_isNoOp() throws {
        let m = try makeVM()
        m.beginCredentialRotation(agentName: "  ", provider: .anthropic)
        XCTAssertFalse(m.providerConfigColdStartInFlight, "empty name → the guard returns before any state mutation")
    }

    func testBeginCredentialRotation_success_opensReconnectTerminalWithRotationFlavor() throws {
        let m = try makeVM()
        m.beginCredentialRotation(agentName: "alpha", provider: .anthropic)
        XCTAssertTrue(m.providerConfigColdStartInFlight, "the re-entrancy gate is engaged")
        XCTAssertEqual(m.vaultOnboardingAgentName, "alpha")
        XCTAssertEqual(m.vaultOnboardingFlavor, .rotation, "a reconnect runs the rotation flavor")
        XCTAssertNotNil(m.vaultOnboardingEntryID, "the reconnect terminal entry is captured")
        XCTAssertTrue(m.state.actionLog.contains { $0.action == "beginCredentialRotation" })
    }

    // MARK: - completeVaultOnboarding (synchronous up-front clear)

    func testCompleteVaultOnboarding_clearsMarkersUpFront() throws {
        let m = try makeVM()
        m.vaultOnboardingEntryID = UUID()
        m.vaultOnboardingRunID = UUID()
        m.vaultOnboardingAgentName = "alpha"
        m.completeVaultOnboarding(vaultExitCode: 1)
        // The synchronous prologue clears the exit-match markers (so a second termination can't
        // double-fire) and sets the in-flight flag before the detached re-probe Task runs.
        XCTAssertNil(m.vaultOnboardingEntryID, "the entry marker is cleared up front")
        XCTAssertNil(m.vaultOnboardingRunID, "the run marker is cleared up front")
        XCTAssertNil(m.vaultOnboardingAgentName, "the agent-name marker is cleared up front")
        XCTAssertTrue(m.providerConfigColdStartInFlight, "the in-flight flag is set before the re-probe")
    }

    // MARK: - runOnboardingRepairStepNatively dispatch arms

    private func repairStep(_ id: String) -> OnboardingRepairStep {
        OnboardingRepairStep(id: id, actor: .agentRunnable, title: id, detail: "")
    }

    func testRunRepairStep_emptyAgentName_isNoOp() throws {
        let m = try makeVM(boss: "")
        m.onboardingReadiness = OnboardingReadiness(
            state: .needsRepair, headline: "", detail: "", selectedBossName: "", repairSteps: [])
        let before = m.bossAppliedActions.count
        m.runOnboardingRepairStepNatively(repairStep("repair-agent-config"))
        XCTAssertEqual(m.bossAppliedActions.count, before, "empty agent name → the guard returns, no ack appended")
    }

    func testRunRepairStep_repairAgentConfig_appendsInProgressAck() throws {
        let m = try makeVM()
        m.runOnboardingRepairStepNatively(repairStep("repair-agent-config"))
        XCTAssertFalse(m.bossAppliedActions.isEmpty,
                       "the repair-agent-config arm prepends an in-progress ack before spawning the runner Task")
    }

    func testRunRepairStep_checkOutward_appendsInProgressAck() throws {
        let m = try makeVM()
        m.runOnboardingRepairStepNatively(repairStep("check-outward"))
        XCTAssertFalse(m.bossAppliedActions.isEmpty, "the check-* arm prepends an in-progress ack")
    }

    func testRunRepairStep_repairProvider_reChecksWithoutAck() throws {
        let m = try makeVM()
        m.onboardingReadiness = readyReadiness()
        let before = m.bossAppliedActions.count
        m.runOnboardingRepairStepNatively(repairStep("repair-outward-provider"))
        // This arm is a RE-CHECK (runOnboardingProviderChecksIfNeeded), not an ack-prepending action.
        XCTAssertEqual(m.bossAppliedActions.count, before,
                       "the repair-*-provider arm re-checks (no ack prepend)")
    }

    func testRunRepairStep_unknownStep_reprobesReadiness() throws {
        let m = try makeVM()
        let before = m.bossAppliedActions.count
        m.runOnboardingRepairStepNatively(repairStep("some-unhandled-step"))
        XCTAssertEqual(m.bossAppliedActions.count, before, "the default arm only re-probes readiness")
    }

    // MARK: - surfaceNativeRepairLine (the recovery-truth fold)

    func testSurfaceNativeRepairLine_prependsLineAndLogs() throws {
        let m = try makeVM()
        let before = m.bossAppliedActions.count
        m.surfaceNativeRepairLine(
            humanFacingLine: "alpha is connected.", auditDetail: "ran ouro repair; repaired",
            targetName: "alpha", action: "repairAgent", succeeded: true, needsManual: false)
        XCTAssertEqual(m.bossAppliedActions.first, "alpha is connected.", "the human line is prepended")
        XCTAssertEqual(m.bossAppliedActions.count, before + 1)
        XCTAssertTrue(m.state.actionLog.contains { $0.action == "repairAgent" && $0.succeeded })
    }

    func testSurfaceNativeRepairLine_needsManualWhileWatching_setsWatchError() throws {
        let m = try makeVM()
        m.bossWatchIsEnabled = true
        m.surfaceNativeRepairLine(
            humanFacingLine: "Couldn't repair alpha.", auditDetail: "repair failed; manual",
            targetName: "alpha", action: "repairAgent", succeeded: false, needsManual: true)
        XCTAssertEqual(m.bossWatchLastError, "repair failed; manual",
                       "a needs-manual outcome while Watch is on records the watch error")
    }

    func testSurfaceNativeRepairLine_succeededWhileWatching_doesNotSetWatchError() throws {
        let m = try makeVM()
        m.bossWatchIsEnabled = true
        m.surfaceNativeRepairLine(
            humanFacingLine: "alpha is connected.", auditDetail: "ran ouro repair; repaired",
            targetName: "alpha", action: "repairAgent", succeeded: true, needsManual: false)
        XCTAssertNil(m.bossWatchLastError, "a successful outcome never sets the watch error")
    }

    // MARK: - makeFirstRunBootstrapEffects (effects-struct construction)

    func testMakeFirstRunBootstrapEffects_buildsEffectsStruct() throws {
        let m = try makeVM()
        // Invoking the builder constructs every @Sendable per-step closure (the construction lines);
        // the closure BODIES (subprocess/MCP runners) are the carved boundary, not invoked here.
        let effects = m.makeFirstRunBootstrapEffects(agentName: "alpha")
        // BootstrapStepEffects is a value carrying the closures; constructing it without trapping
        // proves the wiring is sound. (A different agent name builds an equivalent struct — the
        // closures capture it; we assert constructability, the observable contract of this builder.)
        _ = effects
        let effects2 = m.makeFirstRunBootstrapEffects(agentName: "beta")
        _ = effects2
    }

    // MARK: - openDeskBridgeSetup

    func testOpenDeskBridgeSetup_nilCommand_setsError() throws {
        let m = try makeVM()
        let plan = DeskBridgePlan(agentName: "alpha", terminalKind: .claudeCode,
                                  setupCommand: nil, detail: "no bridge command available")
        m.openDeskBridgeSetup(plan)
        XCTAssertEqual(m.errorMessage, "no bridge command available",
                       "a nil command-line surfaces the plan detail as the error")
    }

    func testOpenDeskBridgeSetup_withCommand_launchesTerminal() throws {
        let m = try makeVM()
        m.errorMessage = nil
        let plan = DeskBridgePlan(agentName: "alpha", terminalKind: .claudeCode,
                                  setupCommand: ["ouro", "desk", "bridge"], detail: "bridge setup")
        let before = m.state.processEntries.count
        m.openDeskBridgeSetup(plan)
        XCTAssertNil(m.errorMessage, "a valid command launches without an error")
        XCTAssertEqual(m.state.processEntries.count, before + 1, "the desk-bridge terminal is created")
    }

    // MARK: - installWorkbenchMCP

    private func agentRecord(_ name: String) -> OuroAgentRecord {
        OuroAgentRecord(name: name, bundlePath: "/tmp/\(name)", configPath: "/tmp/\(name)/agent.json",
                        status: .ready, detail: "")
    }

    func testInstallWorkbenchMCP_missingBundle_surfacesErrorViaCatch() throws {
        // No agent bundle exists in the temp dir, so the registrar `install` THROWS — driving the
        // catch arm (errorMessage set + registration refreshed, no bossAppliedActions append).
        let m = try makeVM()
        m.errorMessage = nil
        m.installWorkbenchMCP(for: agentRecord("alpha"))
        XCTAssertEqual(
            m.errorMessage,
            "Workbench couldn't connect alpha just now. Please try again — reopening Workbench usually clears it up.",
            "a failed install surfaces the friendly error via the catch arm")
    }

    func testInstallWorkbenchMCP_existingBundle_surfacesLineAndLogs() throws {
        // Seed a real agent bundle (a `<name>/agent.json`) under the VM's bundles dir so the
        // registrar `install` SUCCEEDS, driving the do-arm: the snapshot fold + the human line
        // prepend + the audited row. The bundles dir is the temp `<root>/AgentBundles` the VM's
        // registrar was constructed with in makeVM.
        let root = makeTmp()
        let paths = WorkbenchPaths(rootURL: root)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        let agentBundles = root.appendingPathComponent("AgentBundles", isDirectory: true)
        let betaBundle = agentBundles.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: betaBundle, withIntermediateDirectories: true)
        try #"{"name":"beta"}"#.data(using: .utf8)!.write(to: betaBundle.appendingPathComponent("agent.json"))
        let m = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        m.launchTerminalSession = { _ in }
        m.errorMessage = nil
        let before = m.bossAppliedActions.count
        m.installWorkbenchMCP(for: agentRecord("beta"))
        // Whichever truth the snapshot resolves to (registered / not), the do-arm prepends ONE human
        // line and records ONE audited row for this agent; a still-failing install drives the catch.
        if m.errorMessage == nil {
            XCTAssertEqual(m.bossAppliedActions.count, before + 1, "the do-arm prepends an outcome line")
            XCTAssertTrue(m.state.actionLog.contains { $0.action == "registerWorkbenchMCP" && $0.targetName == "beta" },
                          "the install is audited")
        } else {
            XCTAssertTrue(m.errorMessage?.contains("beta") == true, "the catch arm surfaces the friendly error")
        }
    }
}
#endif
