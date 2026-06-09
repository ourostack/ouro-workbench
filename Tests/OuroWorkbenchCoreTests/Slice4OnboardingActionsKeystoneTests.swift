import Foundation
import XCTest
@testable import OuroWorkbenchCore

/// End-to-end coverage for the 5 remaining onboarding actions, mirroring
/// `RepairAgentKeystoneTests`: enqueue → drain (the 2s pump's drain) → authorize
/// (trusted-onboarding, explicit agent name) → headless runner → recovery-truth classification
/// from the POST-command verify probe — against a real file-backed queue. The app wires these
/// exact types in `drainExternalActionRequests` → `applyBossAction` → each `start…` handler.
final class Slice4OnboardingActionsKeystoneTests: XCTestCase {
    private func makeTempQueue() throws -> (WorkbenchActionRequestQueue, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slice4-\(UUID().uuidString)", isDirectory: true)
        return (WorkbenchActionRequestQueue(directoryURL: dir), dir)
    }

    // MARK: - verifyProvider

    func testVerifyProviderFullLoopVerified() async throws {
        let (queue, dir) = try makeTempQueue()
        defer { try? FileManager.default.removeItem(at: dir) }

        try queue.enqueue(WorkbenchActionRequest(
            source: "boss:ouroboros",
            action: BossWorkbenchAction(action: .verifyProvider, name: "slugger", lane: .outward)
        ))
        let action = try XCTUnwrap(try queue.drain().first).action
        XCTAssertEqual(action.action, .verifyProvider)
        XCTAssertEqual(action.lane, .outward)

        // The app authorizes the entry-less action through the SAME gate both call sites use.
        let gate = BossWorkbenchActionAuthorizer().gate(action, resolvedEntry: nil)
        XCTAssertTrue(gate.authorization.isAllowed)
        XCTAssertEqual(gate.authorization.posture, .trustedOnboarding)
        XCTAssertTrue(gate.authorization.requiresAudit)

        let runner = ProviderVerifyRunner(runVerify: { _, _ in }, verifyProbe: { _, _ in .healthy })
        let outcome = await runner.verify(agentName: action.name ?? "", lane: action.lane)
        XCTAssertEqual(outcome.truth, .verified)
        XCTAssertTrue(outcome.auditDetail.contains("ouro check --agent slugger --lane outward"))
    }

    // MARK: - refreshProvider

    func testRefreshProviderFullLoopRefreshed() async throws {
        let (queue, dir) = try makeTempQueue()
        defer { try? FileManager.default.removeItem(at: dir) }

        try queue.enqueue(WorkbenchActionRequest(
            source: "boss:ouroboros",
            action: BossWorkbenchAction(action: .refreshProvider, name: "slugger")
        ))
        let action = try XCTUnwrap(try queue.drain().first).action

        let gate = BossWorkbenchActionAuthorizer().gate(action, resolvedEntry: nil)
        XCTAssertTrue(gate.authorization.isAllowed)
        XCTAssertEqual(gate.authorization.posture, .trustedOnboarding)

        // Refresh "succeeded" (exit 0) but the probe still reads degraded — never a false refreshed.
        let runner = ProviderRefreshRunner(runRefresh: { _ in }, verifyProbe: { _ in .degraded })
        let outcome = await runner.refresh(agentName: action.name ?? "")
        XCTAssertEqual(outcome.truth, .stillDegraded)
        XCTAssertTrue(outcome.auditDetail.contains("ouro provider refresh --agent slugger"))
    }

    // MARK: - selectLane

    func testSelectLaneFullLoopSelected() async throws {
        let (queue, dir) = try makeTempQueue()
        defer { try? FileManager.default.removeItem(at: dir) }

        try queue.enqueue(WorkbenchActionRequest(
            source: "boss:ouroboros",
            action: BossWorkbenchAction(action: .selectLane, name: "slugger", lane: .inner, provider: "anthropic", model: "claude")
        ))
        let action = try XCTUnwrap(try queue.drain().first).action

        let gate = BossWorkbenchActionAuthorizer().gate(action, resolvedEntry: nil)
        XCTAssertTrue(gate.authorization.isAllowed)
        XCTAssertEqual(gate.authorization.posture, .trustedOnboarding)

        let selection = LaneSelection(
            agentName: action.name ?? "",
            lane: try XCTUnwrap(action.lane),
            provider: try XCTUnwrap(action.provider),
            model: try XCTUnwrap(action.model)
        )
        let runner = LaneSelectionRunner(runSelect: { _ in }, verifyProbe: { _ in .healthy })
        let outcome = await runner.select(selection)
        XCTAssertEqual(outcome.truth, .selected)
        XCTAssertTrue(outcome.auditDetail.contains("ouro use --agent slugger --lane inner --provider anthropic --model claude"))
    }

    // MARK: - registerWorkbenchMCP

    func testRegisterWorkbenchMCPFullLoopRegistered() async throws {
        let (queue, dir) = try makeTempQueue()
        defer { try? FileManager.default.removeItem(at: dir) }

        try queue.enqueue(WorkbenchActionRequest(
            source: "boss:ouroboros",
            action: BossWorkbenchAction(action: .registerWorkbenchMCP, name: "slugger")
        ))
        let action = try XCTUnwrap(try queue.drain().first).action

        let gate = BossWorkbenchActionAuthorizer().gate(action, resolvedEntry: nil)
        XCTAssertTrue(gate.authorization.isAllowed)
        XCTAssertEqual(gate.authorization.posture, .trustedOnboarding)

        // The runner wraps the in-app registrar; here we inject deterministic effects. The
        // register throws, but the post-command snapshot reads registered → recovery truth is
        // `registered` (from the snapshot, never the throw).
        let runner = WorkbenchMCPRegistrationRunner(
            runRegister: { _ in throw KeystoneError.boom },
            snapshotProbe: { _ in .registered }
        )
        let outcome = await runner.register(agentName: action.name ?? "")
        XCTAssertEqual(outcome.truth, .registered)
        XCTAssertTrue(outcome.auditDetail.contains("slugger"))
    }

    // MARK: - ensureDaemon (no agent name; wraps DaemonManager)

    func testEnsureDaemonFullLoopRespawned() async throws {
        let (queue, dir) = try makeTempQueue()
        defer { try? FileManager.default.removeItem(at: dir) }

        try queue.enqueue(WorkbenchActionRequest(
            source: "boss:ouroboros",
            action: BossWorkbenchAction(action: .ensureDaemon)
        ))
        let action = try XCTUnwrap(try queue.drain().first).action
        XCTAssertEqual(action.action, .ensureDaemon)
        XCTAssertNil(action.name)

        let gate = BossWorkbenchActionAuthorizer().gate(action, resolvedEntry: nil)
        XCTAssertTrue(gate.authorization.isAllowed)
        XCTAssertEqual(gate.authorization.posture, .trustedOnboarding)

        // Daemon down → started → post-start probe reads up → respawned (from the probe).
        let probeState = DaemonProbeState()
        let manager = DaemonManager(
            probe: DaemonLivenessProbe(reachability: { _ in probeState.reachable }),
            startDaemon: { probeState.markStarted() }
        )
        let start = await manager.ensureRunning()
        let outcome = DaemonEnsureActionOutcome(start: start)
        XCTAssertEqual(start.recovery, .respawned)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertFalse(outcome.needsManualRecovery)
        XCTAssertTrue(outcome.auditDetail.lowercased().contains("ouro up"))
    }

    func testEnsureDaemonFullLoopNeedsManualWhenStillDown() async throws {
        let manager = DaemonManager(
            probe: DaemonLivenessProbe(reachability: { _ in false }),
            startDaemon: { },
            // Small budget + no-op sleep: the always-down probe exhausts the verify budget,
            // so without this the default ~10s polling window would real-sleep in CI.
            verifyConfig: DaemonStartVerifyConfiguration(maxProbeAttempts: 4, probeIntervalNanoseconds: 0),
            sleep: { _ in }
        )
        let outcome = DaemonEnsureActionOutcome(start: await manager.ensureRunning())
        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.needsManualRecovery)
    }

    // MARK: - explicit-agent-name guard (the command never runs without a resolved name)

    func testAgentTargetedRunnersNeverRunTheCommandWithoutAnExplicitName() async throws {
        // Empty agent name → commandAttempted == false (the wrong agent could be acted on).
        let verify = await ProviderVerifyRunner(
            runVerify: { _, _ in XCTFail("verify must not run without an explicit agent name") },
            verifyProbe: { _, _ in .healthy }
        ).verify(agentName: "   ", lane: .outward)
        XCTAssertFalse(verify.commandAttempted)
        XCTAssertEqual(verify.truth, .needsManual)

        let refresh = await ProviderRefreshRunner(
            runRefresh: { _ in XCTFail("refresh must not run without an explicit agent name") },
            verifyProbe: { _ in .healthy }
        ).refresh(agentName: "   ")
        XCTAssertFalse(refresh.commandAttempted)
        XCTAssertEqual(refresh.truth, .needsManual)

        let select = await LaneSelectionRunner(
            runSelect: { _ in XCTFail("select must not run without an explicit agent name") },
            verifyProbe: { _ in .healthy }
        ).select(LaneSelection(agentName: "   ", lane: .inner, provider: "anthropic", model: "claude"))
        XCTAssertFalse(select.commandAttempted)
        XCTAssertEqual(select.truth, .needsManual)

        let register = await WorkbenchMCPRegistrationRunner(
            runRegister: { _ in XCTFail("register must not run without an explicit agent name") },
            snapshotProbe: { _ in .registered }
        ).register(agentName: "   ")
        XCTAssertFalse(register.commandAttempted)
        XCTAssertEqual(register.truth, .needsManual)
    }
}

private enum KeystoneError: Error { case boom }

/// A tiny state box: the daemon reads down until `markStarted()` flips it up, so the
/// before/after probe in `DaemonManager.ensureRunning()` classifies `respawned`.
private final class DaemonProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    var reachable: Bool { lock.lock(); defer { lock.unlock() }; return started }
    func markStarted() { lock.lock(); started = true; lock.unlock() }
}
