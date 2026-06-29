#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 7 — the onboarding remediation handlers:
/// the `start*` dispatchers (`startVerifyProvider` `:8896`, `startRefreshProvider` `:8927`,
/// `startSelectLane`, `startRegisterWorkbenchMCP`, `startEnsureDaemon` `:9035`, `startReportBug`
/// `:9063`), `completeOnboardingAction` (`:9087`), and `completeFirstRunBootstrap` (`:8704`).
/// Each `start*` handler is a synchronous dispatcher: an EMPTY-NAME guard arm (returns the
/// "Skipped …" finishBossAction string) + an in-flight ACK arm (returns the "…ing…" string +
/// records the optimistic action-log row) — both directly INVOKE-able + effect-asserted +
/// mutation-verified. The async remediation Task (the daemon/provider/MCP probe) is the
/// genuine-machinery boundary; we drive the synchronous return only. `completeOnboardingAction`
/// (the settled outcome fold) is driven directly. `completeFirstRunBootstrap`'s 3 presentation
/// arms (handoff / provider-gate / neither) are driven via a crafted `BootstrapResult`.
@MainActor
final class WorkbenchViewModelOnboardingHandlersTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmonbh-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    private func action(_ kind: BossWorkbenchActionKind, name: String? = nil, text: String? = nil) -> BossWorkbenchAction {
        BossWorkbenchAction(action: kind, text: text, name: name)
    }

    // MARK: - start* empty-name guards (the "Skipped …" arm)

    func testStartVerifyProvider_missingName_skips() throws {
        let m = try makeVM()
        let result = m.startVerifyProvider(action: action(.verifyProvider, name: "  "), source: "test")
        XCTAssertEqual(result, "Skipped verifyProvider: missing explicit agent name")
    }

    func testStartRefreshProvider_missingName_skips() throws {
        let m = try makeVM()
        let result = m.startRefreshProvider(action: action(.refreshProvider, name: ""), source: "test")
        XCTAssertEqual(result, "Skipped refreshProvider: missing explicit agent name")
    }

    func testStartReportBug_missingNote_skips() throws {
        let m = try makeVM()
        let result = m.startReportBug(action: action(.reportBug, text: "  "), source: "test")
        XCTAssertEqual(result, "Skipped reportBug: missing note")
    }

    // MARK: - start* in-flight ack arm (the "…ing…" return + optimistic log)

    func testStartVerifyProvider_withName_returnsInFlightAck() throws {
        let m = try makeVM()
        let result = m.startVerifyProvider(action: action(.verifyProvider, name: "alpha"), source: "test")
        XCTAssertEqual(result, "Checking alpha's provider connection…")
        XCTAssertTrue(m.state.actionLog.contains { $0.action == "verifyProvider" },
                      "the optimistic in-flight ack is logged")
    }

    func testStartRefreshProvider_withName_returnsInFlightAck() throws {
        let m = try makeVM()
        let result = m.startRefreshProvider(action: action(.refreshProvider, name: "alpha"), source: "test")
        XCTAssertEqual(result, "Refreshing alpha's connection…")
    }

    func testStartEnsureDaemon_returnsInFlightAck() throws {
        let m = try makeVM()
        let result = m.startEnsureDaemon(action: action(.ensureDaemon), source: "test")
        XCTAssertEqual(result, "Bringing your agent's connection online…")
    }

    // MARK: - completeOnboardingAction (the settled outcome fold)

    func testCompleteOnboardingAction_appendsNarrationAndLogs() throws {
        let m = try makeVM()
        let before = m.bossAppliedActions.count
        m.completeOnboardingAction(
            action: action(.verifyProvider, name: "alpha"), source: "test", targetName: "alpha",
            humanFacingLine: "alpha is connected.", auditDetail: "ran ouro check; verified",
            succeeded: true, needsManual: false)
        XCTAssertEqual(m.bossAppliedActions.first, "alpha is connected.")
        XCTAssertEqual(m.bossAppliedActions.count, before + 1)
        XCTAssertTrue(m.state.actionLog.contains { $0.action == "verifyProvider" && $0.succeeded })
    }

    func testCompleteOnboardingAction_needsManualWhileWatching_setsWatchError() throws {
        let m = try makeVM()
        m.bossWatchIsEnabled = true
        m.completeOnboardingAction(
            action: action(.refreshProvider, name: "alpha"), source: "test", targetName: "alpha",
            humanFacingLine: "Couldn't reconnect alpha.", auditDetail: "refresh failed; manual",
            succeeded: false, needsManual: true)
        XCTAssertEqual(m.bossWatchLastError, "refresh failed; manual",
                       "a needs-manual outcome while Watch is on records the watch error")
    }

    // MARK: - completeFirstRunBootstrap presentation arms

    private func bootstrapResult(_ phase: BootstrapPhase) -> BootstrapResult {
        BootstrapResult(phase: phase, stepOutcomes: [])
    }

    func testCompleteFirstRunBootstrap_handoff_surfacesAgentDrivenNarration() throws {
        let m = try makeVM()
        m.completeFirstRunBootstrap(result: bootstrapResult(.handedOff), agentName: "boss")
        XCTAssertFalse(m.firstRunBootstrapIsRunning, "the bootstrap is no longer running")
        XCTAssertNotNil(m.firstRunAgentDrivenNarration, "handoff surfaces the agent-driven narration")
        XCTAssertEqual(m.firstRunAgentDrivenNarration, FirstRunBootstrapDrive.agentDrivenHandoffNarration)
    }

    func testCompleteFirstRunBootstrap_parked_opensProviderForm() throws {
        let m = try makeVM()
        m.completeFirstRunBootstrap(result: bootstrapResult(.parkedAwaitingProviderConfig), agentName: "boss")
        XCTAssertNil(m.firstRunAgentDrivenNarration, "the parked arm clears the narration")
        XCTAssertTrue(m.isProviderConfigPresented, "the S2 park surfaces the native provider form")
    }

    func testCompleteFirstRunBootstrap_failed_clearsNarrationNoForm() throws {
        let m = try makeVM()
        // .failedInvalidAgent is neither a handoff nor the S2 provider-gate park → the else arm.
        m.completeFirstRunBootstrap(result: bootstrapResult(.failedInvalidAgent), agentName: "boss")
        XCTAssertNil(m.firstRunAgentDrivenNarration)
        XCTAssertFalse(m.isProviderConfigPresented, "a failed (non-parked) bootstrap opens no form")
        XCTAssertTrue(m.state.actionLog.contains { $0.action == "firstRunBootstrap" })
    }

    // MARK: - Negative control (mutation-verified)

    func testNegativeControl_skipArmDistinctFromAck() throws {
        // The empty-name guard MUST return the "Skipped" string, never the ack. A dropped guard
        // would return "Checking …" → RED.
        let m = try makeVM()
        let result = m.startVerifyProvider(action: action(.verifyProvider, name: ""), source: "test")
        XCTAssertTrue(result.hasPrefix("Skipped"), "empty name → the skip arm, not the ack")
    }
}
#endif
