import Foundation
import XCTest
@testable import OuroWorkbenchCore

/// KEYSTONE end-to-end coverage for the first agent-driven remediation.
///
/// Drives the SAME Core seam the app composes — enqueue → drain (the 2s pump's drain) →
/// authorize (trusted-onboarding) → headless repair runner → recovery-truth classification
/// from the POST-command verify probe — against a real file-backed queue. The app wires
/// these exact types in `drainExternalActionRequests` → `applyBossAction` →
/// `startRepairAgent` → `AgentRepairRunner.repair`; the live MCP-binary half of the loop
/// (boss → `workbench_request_action` → enqueue) is proven separately by driving the binary
/// over stdio. The full live-daemon/agent run is an env-gated test below (never fabricated).
final class RepairAgentKeystoneTests: XCTestCase {
    private func makeTempQueue() throws -> (WorkbenchActionRequestQueue, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keystone-\(UUID().uuidString)", isDirectory: true)
        let queue = WorkbenchActionRequestQueue(directoryURL: dir)
        return (queue, dir)
    }

    func testFullLoopEnqueueDrainAuthorizeExecuteClassifyRepaired() async throws {
        let (queue, dir) = try makeTempQueue()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Boss issues repairAgent (what `workbench_request_action` enqueues) with an
        //    EXPLICIT agent name — never default-agent resolution.
        let request = WorkbenchActionRequest(
            source: "boss:ouroboros",
            action: BossWorkbenchAction(action: .repairAgent, name: "slugger")
        )
        try queue.enqueue(request)

        // 2. The 2s pump drains it.
        let drained = try queue.drain()
        XCTAssertEqual(drained.count, 1)
        let action = try XCTUnwrap(drained.first).action
        XCTAssertEqual(action.action, .repairAgent)
        XCTAssertEqual(action.name, "slugger")

        // 3. The app authorizes the entry-less action through the SAME gate both call sites
        //    use, then under the trusted-onboarding posture. This is the exact decision
        //    `applyBossAction`'s first-switch guard makes before `startRepairAgent` runs.
        let gate = BossWorkbenchActionAuthorizer().gate(action, resolvedEntry: nil)
        XCTAssertTrue(gate.authorization.isAllowed)
        XCTAssertEqual(gate.authorization.posture, .trustedOnboarding)
        XCTAssertTrue(gate.authorization.requiresAudit)

        // 4. Headless execution + POST-command verify probe → recovery truth. Probe reads
        //    healthy here, so the outcome is `repaired` (classified from the probe, not exit).
        let runner = AgentRepairRunner(
            runRepair: { _ in },
            verifyProbe: { _ in .healthy }
        )
        let outcome = await runner.repair(agentName: action.name ?? "")

        XCTAssertEqual(outcome.truth, .repaired)
        XCTAssertEqual(outcome.agentName, "slugger")
        XCTAssertTrue(outcome.commandAttempted)
        // 5. The recovery-truth audit line that surfaces in bossAppliedActions.
        XCTAssertEqual(outcome.humanFacingLine, "slugger is back online and ready.")
        XCTAssertTrue(outcome.auditDetail.contains("ouro repair --agent slugger"))
        XCTAssertFalse(outcome.needsManualRecovery)
    }

    func testFullLoopSurfacesStillDegradedWhenProbeStillDegraded() async throws {
        let (queue, dir) = try makeTempQueue()
        defer { try? FileManager.default.removeItem(at: dir) }

        try queue.enqueue(
            WorkbenchActionRequest(
                source: "boss:ouroboros",
                action: BossWorkbenchAction(action: .repairAgent, name: "slugger")
            )
        )
        let action = try XCTUnwrap(try queue.drain().first).action

        // Repair "succeeded" (exit 0) but the agent is still degraded — never a false repaired.
        let runner = AgentRepairRunner(
            runRepair: { _ in },
            verifyProbe: { _ in .degraded }
        )
        let outcome = await runner.repair(agentName: action.name ?? "")

        XCTAssertEqual(outcome.truth, .stillDegraded)
        XCTAssertFalse(outcome.needsManualRecovery)
    }

    func testFullLoopSurfacesNeedsManualWhenProbeUnreachable() async throws {
        let runner = AgentRepairRunner(
            runRepair: { _ in },
            verifyProbe: { _ in .unreachable }
        )
        let outcome = await runner.repair(agentName: "slugger")

        XCTAssertEqual(outcome.truth, .needsManual)
        XCTAssertTrue(outcome.needsManualRecovery)
        XCTAssertEqual(
            outcome.humanFacingLine,
            "Workbench couldn't bring slugger back online automatically. Please reopen Workbench, and if it keeps happening, restart your Mac."
        )
    }

    func testEntrylessBypassClosed_unknownEntrylessActionDeniedAfterDrain() throws {
        // Defense in depth: even if a non-onboarding, non-known entry-less action reached the
        // queue, the entry-less authorizer denies it — it can never slip through unauthorized.
        let action = BossWorkbenchAction(action: .terminate)
        let authorization = BossWorkbenchActionAuthorizer().authorizeEntryless(action)

        XCTAssertFalse(authorization.isAllowed)
        XCTAssertEqual(authorization.reason, "terminate is not authorized without a target entry")
    }

    /// KEYSTONE SECURITY INVARIANT: the additive merge did not let the keystone open a
    /// destructive-input hole. A dangerous `sendInput` arriving WITHOUT an entry is denied by
    /// the entry-less gate (it can't reach the entry-scoped floor entry-less), and a dangerous
    /// `sendInput` WITH a trusted entry is still withheld by live's `livePrompt` floor — the
    /// exact path `applyBossAction`'s second switch takes. Both must hold simultaneously, so
    /// closing the bypass and adding the keystone never expands the destructive-input surface.
    func testKeystoneNeverOpensDestructiveInputHole() throws {
        let authorizer = BossWorkbenchActionAuthorizer()

        // Entry-less dangerous sendInput: denied by the gate (cannot reach the floor).
        let entryless = BossWorkbenchAction(action: .sendInput, text: "rm -rf /")
        let entrylessGate = authorizer.gate(entryless, resolvedEntry: nil)
        XCTAssertFalse(entrylessGate.authorization.isAllowed)
        XCTAssertEqual(entrylessGate.authorization.reason, "sendInput is not authorized without a target entry")

        // Entry-scoped dangerous sendInput on a TRUSTED session: still withheld by the floor.
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Trusted",
            kind: .terminalAgent,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted
        )
        let scoped = BossWorkbenchAction(action: .sendInput, entry: entry.id.uuidString, text: "y")
        let scopedGate = authorizer.gate(scoped, resolvedEntry: entry, livePrompt: "Run 'rm -rf /'? [y/N]")
        XCTAssertFalse(scopedGate.authorization.isAllowed)
        XCTAssertEqual(scopedGate.authorization.reason, "withheld unsafe input (destructive command) — escalated to a human")
    }

    /// LIVE architecture-proof — runs the REAL headless repair + REAL status verify probe
    /// against a real agent. Skipped unless `OURO_WORKBENCH_LIVE_REPAIR` is set (needs `ouro`
    /// on PATH + a real agent), so the normal `swift test` stays deterministic and offline.
    ///
    /// Set `OURO_WORKBENCH_LIVE_REPAIR=<agentName>` to run it (e.g. `slugger`).
    func testLiveRepairAgentLoopAgainstRealAgent() async throws {
        guard let agentName = ProcessInfo.processInfo.environment["OURO_WORKBENCH_LIVE_REPAIR"],
              !agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Set OURO_WORKBENCH_LIVE_REPAIR=<agentName> to run the live repair loop.")
        }

        let client = BossAgentMCPClient(timeoutNanoseconds: 60_000_000_000)
        let runner = AgentRepairRunner(
            runRepair: AgentRepairRunner.headlessRepair,
            verifyProbe: { name in
                do {
                    _ = try await client.status(agentName: name)
                    return .healthy
                } catch {
                    return .unreachable
                }
            }
        )

        let outcome = await runner.repair(agentName: agentName)

        // The command was attempted and the outcome was classified from the PROBE — assert
        // the loop produced a real recovery-truth line (any of the three is a valid outcome;
        // the point is the loop ran end-to-end and classified honestly, never off exit code).
        XCTAssertTrue(outcome.commandAttempted)
        XCTAssertEqual(outcome.agentName, agentName)
        print("LIVE repairAgent loop → truth=\(outcome.truth.rawValue) | human=\(outcome.humanFacingLine) | audit=\(outcome.auditDetail)")
    }
}
