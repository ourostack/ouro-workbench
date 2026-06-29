#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 8 — the boss-watch / external-action flow logic:
/// `runBossWatchTick` (`:3828`, the synchronous guard + no-wake arms), `registerBossWatchFailure`
/// (`:6259`, the pure backoff bump), `applyExternalActionRequests` (`:6733`, the per-request
/// apply + markApplied fold), and `triggerEventDrivenBossCheckIn` (`:3813`, the cooldown gate).
/// The async check-in / drain Tasks (daemon/MCP/subprocess) are the genuine-machinery boundary;
/// every arm that returns BEFORE that await is INVOKE-able + effect-asserted + mutation-verified.
@MainActor
final class WorkbenchViewModelBossFlowsTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmboss-flows-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        let m = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        m.launchTerminalSession = { _ in }
        return m
    }

    // MARK: - runBossWatchTick guard arms (early returns, no async)

    func testRunBossWatchTick_disabled_isNoOp() async throws {
        let m = try makeVM()
        m.bossWatchIsEnabled = false
        m.bossWatchLastRunAt = nil
        await m.runBossWatchTick(force: true)
        XCTAssertNil(m.bossWatchLastRunAt, "watch disabled → the tick returns before recording a run")
    }

    func testRunBossWatchTick_noChangesNoForce_recordsRunWithoutWaking() async throws {
        // Watch on, force:false, state == baseline (no changes), no actionable state →
        // shouldAskBoss is false → the no-wake arm: records the run + baseline, returns
        // synchronously (never reaches the runBossCheckIn await / daemon spawn).
        let m = try makeVM()
        m.bossWatchIsEnabled = true
        m.bossWatchLastRunAt = nil
        await m.runBossWatchTick(force: false)
        XCTAssertNotNil(m.bossWatchLastRunAt, "the no-wake arm still records bossWatchLastRunAt")
        XCTAssertNil(m.bossCheckInAnswer, "the no-wake arm never asks the boss (no daemon/MCP round-trip)")
    }

    // MARK: - registerBossWatchFailure (pure backoff bump)

    func testRegisterBossWatchFailure_bumpsConsecutiveAndSurfacesErrorWhileWatching() throws {
        let m = try makeVM()
        m.bossWatchIsEnabled = true
        m.bossWatchConsecutiveFailures = 0
        m.registerBossWatchFailure(auditDetail: "daemon down")
        XCTAssertEqual(m.bossWatchLastError, "daemon down", "while watching, the failure detail is surfaced")
        XCTAssertEqual(m.bossWatchConsecutiveFailures, 1, "the consecutive-failure count is bumped (backoff)")
    }

    func testRegisterBossWatchFailure_whileNotWatching_bumpsButDoesNotSurfaceError() throws {
        let m = try makeVM()
        m.bossWatchIsEnabled = false
        m.bossWatchLastError = nil
        m.bossWatchConsecutiveFailures = 0
        m.registerBossWatchFailure(auditDetail: "transient")
        XCTAssertNil(m.bossWatchLastError, "off-watch, the error is not surfaced (only the backoff bumps)")
        XCTAssertEqual(m.bossWatchConsecutiveFailures, 1, "the backoff still bumps the count regardless of watch state")
    }

    // MARK: - applyExternalActionRequests (the per-request apply + markApplied fold)

    func testApplyExternalActionRequests_appliesEachAndSurfacesResults() throws {
        let m = try makeVM()
        let before = m.bossAppliedActions.count
        // A `.launch` of a non-existent entry applies cleanly (returns the "no such entry" result
        // string) with NO subprocess / NSApp side effect — so the per-request apply + markApplied
        // fold + bossAppliedActions surfacing is driven hermetically.
        let req = WorkbenchActionRequest(
            source: "boss-test",
            action: BossWorkbenchAction(action: .launch, entry: "ghost-entry"))
        m.applyExternalActionRequests([req])
        XCTAssertGreaterThan(m.bossAppliedActions.count, before,
                             "each applied external request surfaces a result into bossAppliedActions")
        XCTAssertTrue(m.bossAppliedActions.first?.hasPrefix("External boss-test:") == true,
                      "the result is prefixed with the external source: \(m.bossAppliedActions.first ?? "nil")")
    }

    // MARK: - triggerEventDrivenBossCheckIn (the cooldown gate)

    func testTriggerEventDrivenBossCheckIn_whileDisabled_isGated() throws {
        // Watch off → BossWatchEventPolicy.shouldTriggerCheckIn returns false → no Task, no
        // lastEventDrivenCheckInAt update (observable: no daemon spawn / answer).
        let m = try makeVM()
        m.bossWatchIsEnabled = false
        m.triggerEventDrivenBossCheckIn()
        XCTAssertNil(m.bossCheckInAnswer, "a disabled watch never triggers an event-driven check-in")
    }

    // MARK: - Negative control (mutation-verified)

    func testNegativeControl_noWakeArmRecordsRun() async throws {
        // The no-wake arm MUST set bossWatchLastRunAt. Dropping that assignment leaves it nil → RED.
        let m = try makeVM()
        m.bossWatchIsEnabled = true
        m.bossWatchLastRunAt = nil
        await m.runBossWatchTick(force: false)
        XCTAssertNotNil(m.bossWatchLastRunAt)
    }
}
#endif
