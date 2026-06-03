import XCTest
@testable import OuroWorkbenchCore

final class HarnessStatusTests: XCTestCase {
    // MARK: - Fixtures

    private func agent(
        _ name: String,
        status: OuroAgentBundleStatus = .ready,
        detail: String = "ready"
    ) -> OuroAgentRecord {
        OuroAgentRecord(
            name: name,
            bundlePath: "/Users/x/AgentBundles/\(name).ouro",
            configPath: "/Users/x/AgentBundles/\(name).ouro/agent.json",
            status: status,
            detail: detail
        )
    }

    private func registration(
        _ name: String,
        status: BossWorkbenchMCPRegistrationStatus
    ) -> BossWorkbenchMCPRegistrationSnapshot {
        BossWorkbenchMCPRegistrationSnapshot(
            agentName: name,
            serverName: "ouro_workbench",
            commandPath: "/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP",
            agentConfigPath: "/Users/x/AgentBundles/\(name).ouro/agent.json",
            status: status,
            detail: "detail for \(name)"
        )
    }

    private func dashboard(
        daemonStatus: String,
        daemonMode: String = "production",
        daemonVersion: String? = nil,
        observedAt: String? = "2026-06-03T00:00:00Z",
        machineAvailable: Bool = true,
        issues: [String] = []
    ) -> BossDashboardSnapshot {
        BossDashboardSnapshot(
            agentName: "slugger",
            daemonStatus: daemonStatus,
            daemonMode: daemonMode,
            daemonVersion: daemonVersion,
            attentionLabel: "active",
            openObligations: 0,
            activeCodingAgents: 0,
            blockedCodingAgents: 0,
            needsMeItems: [],
            codingItems: [],
            observedAt: observedAt,
            availability: BossDashboardAvailability(
                machineAvailable: machineAvailable,
                needsMeAvailable: machineAvailable,
                codingAvailable: machineAvailable,
                issues: issues
            )
        )
    }

    // MARK: - Healthy machine

    func testHealthyMachineSummarizesAllThreeSections() {
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            dashboard: dashboard(daemonStatus: "running", daemonVersion: "0.1.0-alpha.657"),
            agents: [agent("boss-b"), agent("slugger")],
            bossRegistration: registration("slugger", status: .registered),
            registrationByAgentName: [
                "slugger": registration("slugger", status: .registered),
                "boss-b": registration("boss-b", status: .notRegistered)
            ]
        )

        // Daemon
        XCTAssertTrue(status.daemon.isReachable)
        XCTAssertEqual(status.daemon.statusText, "running")
        XCTAssertEqual(status.daemon.modeText, "production")
        XCTAssertEqual(status.daemon.versionText, "0.1.0-alpha.657")

        // Agents — selected boss is marked, registration carried per-agent.
        XCTAssertEqual(status.agents.total, 2)
        XCTAssertEqual(status.agents.readyCount, 2)
        XCTAssertEqual(status.agents.selectedBoss?.name, "slugger")
        XCTAssertEqual(status.agents.selectedBoss?.mcpStatus, .registered)
        XCTAssertFalse(status.agents.hasUnready)

        // Boss reachability
        XCTAssertTrue(status.boss.isReachable)
        XCTAssertEqual(status.boss.mcpStatusText, "registered")
        XCTAssertEqual(status.boss.bundleText, "installed and ready")

        // Roll-up
        XCTAssertEqual(status.overallState, .healthy)
        XCTAssertEqual(status.observedAt, "2026-06-03T00:00:00Z")
        XCTAssertEqual(status.headline, "Daemon up · 2 of 2 agents ready · boss slugger reachable")
    }

    // MARK: - Daemon down + 2 agents (the prompt's worked example)

    func testDaemonDownWithTwoAgentsSummarizesAsBlocked() {
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            dashboard: dashboard(
                daemonStatus: "unknown",
                machineAvailable: false,
                issues: ["machine: The Ouro mailbox did not answer before the Workbench timeout."]
            ),
            agents: [agent("boss-b"), agent("slugger")],
            bossRegistration: registration("slugger", status: .registered),
            registrationByAgentName: [
                "slugger": registration("slugger", status: .registered),
                "boss-b": registration("boss-b", status: .registered)
            ]
        )

        // Daemon read failed — surfaced as unreachable with the real reason,
        // not a bare "unknown".
        XCTAssertFalse(status.daemon.isReachable)
        XCTAssertEqual(status.daemon.state, .blocked)
        XCTAssertEqual(
            status.daemon.statusText,
            "unreachable (The Ouro mailbox did not answer before the Workbench timeout.)"
        )

        // Agents are still scannable from disk even with the daemon down.
        XCTAssertEqual(status.agents.total, 2)
        XCTAssertEqual(status.agents.readyCount, 2)

        // The roll-up leads with the daemon, since that's the blocking problem.
        XCTAssertEqual(status.overallState, .blocked)
        XCTAssertTrue(status.headline.contains("ouro daemon is unreachable"))
    }

    // MARK: - Boss not registered

    func testBossNotRegisteredIsNotReachableAndBlocks() {
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            dashboard: dashboard(daemonStatus: "running"),
            agents: [agent("slugger")],
            bossRegistration: registration("slugger", status: .notRegistered),
            registrationByAgentName: ["slugger": registration("slugger", status: .notRegistered)]
        )

        XCTAssertTrue(status.daemon.isReachable)
        XCTAssertFalse(status.boss.isReachable)
        XCTAssertEqual(status.boss.mcpStatusText, "not registered")
        XCTAssertEqual(status.boss.state, .blocked)
        XCTAssertEqual(status.overallState, .blocked)
        XCTAssertEqual(status.headline, "Boss slugger is not reachable")
    }

    // MARK: - Boss bundle missing from inventory

    func testBossMissingFromInventoryIsNotReady() {
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "ghost"),
            dashboard: dashboard(daemonStatus: "running"),
            agents: [agent("slugger")],
            bossRegistration: registration("ghost", status: .agentMissing),
            registrationByAgentName: ["slugger": registration("slugger", status: .registered)]
        )

        XCTAssertNil(status.agents.selectedBoss)
        XCTAssertFalse(status.boss.bundleIsReady)
        XCTAssertEqual(status.boss.bundleText, "missing or not ready")
        XCTAssertFalse(status.boss.isReachable)
        XCTAssertEqual(status.boss.state, .blocked)
    }

    // MARK: - Registered-but-stale boss is usable-with-attention

    func testNeedsUpdateBossIsAttentionNotBlockedWhenBundleReady() {
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            dashboard: dashboard(daemonStatus: "running"),
            agents: [agent("slugger")],
            bossRegistration: registration("slugger", status: .needsUpdate),
            registrationByAgentName: ["slugger": registration("slugger", status: .needsUpdate)]
        )

        // needsUpdate ⇒ not "reachable" (must be .registered), but the boss
        // sub-state is attention (works today) rather than blocked.
        XCTAssertFalse(status.boss.isReachable)
        XCTAssertEqual(status.boss.state, .attention)
        XCTAssertEqual(status.boss.mcpStatusText, "update needed")
    }

    // MARK: - Unready agent drives attention even when boss is fine

    func testDisabledAgentDrivesAttentionState() {
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            dashboard: dashboard(daemonStatus: "running"),
            agents: [
                agent("slugger"),
                agent("retired", status: .disabled, detail: "disabled in agent.json")
            ],
            bossRegistration: registration("slugger", status: .registered),
            registrationByAgentName: ["slugger": registration("slugger", status: .registered)]
        )

        XCTAssertTrue(status.agents.hasUnready)
        XCTAssertEqual(status.agents.readyCount, 1)
        XCTAssertEqual(status.agents.total, 2)
        // Daemon up + boss reachable, but an unready agent keeps it at attention.
        XCTAssertEqual(status.overallState, .attention)
    }

    // MARK: - No dashboard yet (pre-first-refresh)

    func testNoDashboardYetReportsDaemonNotChecked() {
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            dashboard: nil,
            agents: [],
            bossRegistration: nil
        )

        XCTAssertFalse(status.daemon.isReachable)
        XCTAssertEqual(status.daemon.statusText, "unreachable (not checked yet)")
        XCTAssertEqual(status.daemon.state, .blocked)
        XCTAssertTrue(status.agents.isEmpty)
        XCTAssertEqual(status.agents.summaryLine, "No local agents found in ~/AgentBundles")
        XCTAssertEqual(status.overallState, .blocked)
    }

    // MARK: - Empty inventory headline is grammatical

    func testSingleAgentHeadlineIsSingular() {
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            dashboard: dashboard(daemonStatus: "running"),
            agents: [agent("slugger")],
            bossRegistration: registration("slugger", status: .registered),
            registrationByAgentName: ["slugger": registration("slugger", status: .registered)]
        )

        XCTAssertEqual(status.headline, "Daemon up · 1 of 1 agent ready · boss slugger reachable")
    }
}
