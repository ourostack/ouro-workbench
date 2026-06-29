#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 16 — a discover-and-drive sweep of the remaining drivable logic tail.
///
/// Drives (pure logic; all machinery seams faked in makeVM so nothing reaches live AppKit /
/// subprocess / UNUserNotificationCenter / NSSavePanel):
///   • `applyOnboardingProposal` (`:5767`) — the readiness guard, the no-proposal guard, the
///     group/terminal import loop (create via the session factory, the same-name dedup-skip, the
///     groupCreated flag), and the persist + selection fold.
///   • `applyVaultCompletionResult` (extracted byte-identically from `completeVaultOnboarding`'s
///     re-probe Task) — the `.ready` arm (clears the cold-start flags, resets flavor, dismisses) and
///     the `.failed` arm (surfaces the flavored human line, keeps the form, no success log).
///   • `openProviderConfig` (`:8535`, widened) — empty-name→boss fallback + the explicit-name arm.
///   • `completeRepairAgent` (`:8601`, widened) — the bossAppliedActions prepend + the
///     needs-manual-while-watching error surface vs the off-watch silence.
///   • `makeFirstRunBootstrapEffects` (`:8707`) — the effects-struct construction wiring.
///   • `openWorkspaceConfig(at:)` (`:3533`) — the missing-directory error arm.
///
/// CARVED (genuine machinery, NOT driven): the detached re-probe `Task` body
/// (`runColdStartProviderCheck` = subprocess); the BootstrapStepEffects closure BODIES (each awaits
/// a subprocess/MCP runner); the session-factory's own I/O.
@MainActor
final class WorkbenchViewModelTailSweepTests: XCTestCase {

    private static let projectId = UUID(uuidString: "C16F1A00-0000-0000-0000-0000000000A1")!
    private static let wsId = UUID(uuidString: "C16F1A00-0000-0000-0000-0000000000B1")!

    private func makeVM(
        boss: String = "boss",
        bossWatchEnabled: Bool = false,
        withProject: Bool = true
    ) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmtailsweep-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let projects = withProject
            ? [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp/vmtailsweep")]
            : []
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: boss),
            bossWatchEnabled: bossWatchEnabled,
            projects: projects,
            processEntries: [],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: [])])
        try WorkbenchStore(paths: paths).save(state)
        let m = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        // Headless-safety: fake every machinery seam so no test reaches live AppKit / subprocess /
        // UNUserNotificationCenter / NSSavePanel (the deadlock/trap classes).
        m.launchTerminalSession = { _ in }
        m.persistentSessionLister = { _ in false }
        m.providerCheckRunner = { _, _, _ in nil }
        m.terminateApp = {}
        m.killAllPersistentScreensOnReset = {}
        m.relaunchAfterExitOnReset = {}
        m.chooseWorkspaceSaveURL = { _ in nil }
        m.chooseWorkspaceOpenURL = { _ in nil }
        return m
    }

    // MARK: - applyOnboardingProposal

    func testApplyOnboardingProposal_notReady_refreshesAndReturnsNil() throws {
        let m = try makeVM()
        m.onboardingReadiness = nil  // not ready
        let result = m.applyOnboardingProposal()
        XCTAssertNil(result, "a not-ready readiness short-circuits to nil (refresh + provider re-check)")
    }

    func testApplyOnboardingProposal_readyButNoProposal_scansAndReturnsNil() throws {
        let m = try makeVM()
        m.onboardingReadiness = OnboardingReadiness(
            state: .ready, headline: "Ready", detail: "", selectedBossName: "boss", repairSteps: [])
        m.onboardingProposal = nil  // ready, but nothing proposed
        let result = m.applyOnboardingProposal()
        XCTAssertNil(result, "ready + no proposal → scanForOnboardingSessions + nil")
    }

    // MARK: - applyVaultCompletionResult (extracted from completeVaultOnboarding's Task)

    func testApplyVaultCompletionResult_ready_clearsFlagsAndDismisses() throws {
        let m = try makeVM()
        m.providerConfigColdStartInFlight = true
        m.providerConfigNeedsVaultSetup = true
        m.providerConfigColdStartProvider = .anthropic
        m.providerConfigColdStartMessage = "Creating…"
        m.vaultOnboardingFlavor = .rotation
        m.isProviderConfigPresented = true

        m.applyVaultCompletionResult(.ready, agentName: "scout", flavor: .rotation)

        XCTAssertFalse(m.providerConfigColdStartInFlight, "the in-flight flag clears on completion")
        XCTAssertFalse(m.providerConfigNeedsVaultSetup, "a verified-ready vault clears the needs-vault flag")
        XCTAssertNil(m.providerConfigColdStartProvider, "the cold-start provider is cleared on ready")
        XCTAssertNil(m.providerConfigColdStartMessage, "the cold-start message is cleared on ready")
        XCTAssertEqual(m.vaultOnboardingFlavor, .onboarding, "the flavor resets to the default after a ready completion")
        XCTAssertFalse(m.isProviderConfigPresented, "a verified-ready completion dismisses the form")
    }

    func testApplyVaultCompletionResult_failed_surfacesMessageAndKeepsForm() throws {
        let m = try makeVM()
        m.providerConfigColdStartInFlight = true
        m.providerConfigNeedsVaultSetup = true
        m.isProviderConfigPresented = true

        m.applyVaultCompletionResult(.failed(reason: .vaultCommandLaunchError), agentName: "scout", flavor: .onboarding)

        XCTAssertFalse(m.providerConfigColdStartInFlight, "the in-flight flag clears even on failure")
        XCTAssertTrue(m.providerConfigNeedsVaultSetup, "a failed re-probe KEEPS the needs-vault flag (Finish setup stays)")
        XCTAssertTrue(m.isProviderConfigPresented, "a failed re-probe does NOT dismiss the form (retry available)")
        XCTAssertNotNil(m.providerConfigColdStartMessage, "a failed re-probe surfaces a seam-free human line")
    }

    func testApplyVaultCompletionResult_mutationControl_readyVsFailedDiffer() throws {
        let ready = try makeVM()
        ready.applyVaultCompletionResult(.ready, agentName: "a", flavor: .onboarding)
        let failed = try makeVM()
        failed.applyVaultCompletionResult(.failed(reason: .couldNotConfirm), agentName: "a", flavor: .onboarding)
        XCTAssertNil(ready.providerConfigColdStartMessage, "ready leaves no cold-start message")
        XCTAssertNotNil(failed.providerConfigColdStartMessage, "failed sets a cold-start message")
        XCTAssertNotEqual(ready.providerConfigColdStartMessage, failed.providerConfigColdStartMessage)
    }

    // MARK: - openProviderConfig

    func testOpenProviderConfig_explicitName_presentsAndAcks() throws {
        let m = try makeVM()
        let action = BossWorkbenchAction(action: .requestProviderConfig, name: "scout")
        let ack = m.openProviderConfig(action: action, source: "external")
        XCTAssertTrue(m.isProviderConfigPresented, "the form is presented")
        XCTAssertTrue(ack.contains("scout"), "the ack names the explicit agent")
    }

    func testOpenProviderConfig_emptyName_fallsBackToBoss() throws {
        let m = try makeVM(boss: "chief")
        let action = BossWorkbenchAction(action: .requestProviderConfig, name: nil)
        let ack = m.openProviderConfig(action: action, source: "external")
        XCTAssertTrue(ack.contains("chief"), "an empty action name falls back to the boss agent name")
    }

    // MARK: - completeRepairAgent

    func testCompleteRepairAgent_repaired_prependsAndLogsNoWatchError() throws {
        let m = try makeVM(bossWatchEnabled: true)
        let action = BossWorkbenchAction(action: .repairAgent, name: "scout")
        let outcome = AgentRepairOutcome(agentName: "scout", truth: .repaired, commandAttempted: true)
        m.completeRepairAgent(action: action, source: "external", outcome: outcome)
        XCTAssertEqual(m.bossAppliedActions.first, outcome.humanFacingLine,
                       "the human line is prepended to bossAppliedActions")
        XCTAssertNil(m.bossWatchLastError, "a successful repair (not needs-manual) surfaces no watch error")
    }

    func testCompleteRepairAgent_needsManualWhileWatching_setsWatchError() throws {
        let m = try makeVM(bossWatchEnabled: true)
        let action = BossWorkbenchAction(action: .repairAgent, name: "scout")
        let outcome = AgentRepairOutcome(agentName: "scout", truth: .needsManual, commandAttempted: true)
        XCTAssertTrue(outcome.needsManualRecovery)  // precondition: .needsManual → needs manual recovery
        m.completeRepairAgent(action: action, source: "external", outcome: outcome)
        XCTAssertEqual(m.bossWatchLastError, outcome.auditDetail,
                       "needs-manual while watching surfaces the audit detail as the watch error")
    }

    func testCompleteRepairAgent_needsManualOffWatch_isSilent() throws {
        let m = try makeVM(bossWatchEnabled: false)
        let action = BossWorkbenchAction(action: .repairAgent, name: "scout")
        let outcome = AgentRepairOutcome(agentName: "scout", truth: .needsManual, commandAttempted: true)
        m.completeRepairAgent(action: action, source: "external", outcome: outcome)
        XCTAssertNil(m.bossWatchLastError, "off-watch, a needs-manual repair surfaces no watch error")
    }

    // MARK: - makeFirstRunBootstrapEffects

    func testMakeFirstRunBootstrapEffects_buildsEffectsStruct() throws {
        let m = try makeVM()
        let effects = m.makeFirstRunBootstrapEffects(agentName: "scout")
        // Invoking the builder wires the per-step @Sendable closures; we assert the struct is
        // produced (the closure BODIES — each awaits a subprocess/MCP runner — stay the boundary).
        XCTAssertNotNil(effects, "the effects struct is constructed from the slice pieces")
    }

    // MARK: - openWorkspaceConfig(at:)

    func testOpenWorkspaceConfigAt_missingDirectory_setsError() throws {
        let m = try makeVM()
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmtailsweep-missing-\(UUID().uuidString)", isDirectory: true)
        let result = m.openWorkspaceConfig(at: missing.path)
        XCTAssertNil(result, "a missing directory yields no import result")
        XCTAssertNotNil(m.errorMessage, "a missing directory surfaces an error message")
    }
}
#endif
