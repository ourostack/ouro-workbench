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
        XCTAssertEqual(status.boss.mcpStatusText, "available at runtime")
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
        XCTAssertEqual(status.boss.mcpStatusText, "tools binary missing")
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
        XCTAssertEqual(status.boss.mcpStatusText, "stale entry to clean")
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
        XCTAssertEqual(status.agents.summaryLine, "No Ouro agents are installed on this machine yet")
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

    // MARK: - Control-action offer (W3 harness control panel)

    func testHealthyHarnessOffersRepairButNotUrgentAndNoRegister() {
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            dashboard: dashboard(daemonStatus: "running"),
            agents: [agent("slugger")],
            bossRegistration: registration("slugger", status: .registered),
            registrationByAgentName: ["slugger": registration("slugger", status: .registered)]
        )

        let offer = status.controlOffer
        // Repair is always available (restarting a running daemon is harmless)
        // but NOT urgent when the daemon is reachable.
        XCTAssertTrue(offer.isAvailable(.repairDaemon))
        XCTAssertFalse(offer.isUrgent(.repairDaemon))
        // Register isn't offered at all — the boss is already registered.
        XCTAssertFalse(offer.isAvailable(.registerWorkbenchMCP))
        XCTAssertFalse(offer.isUrgent(.registerWorkbenchMCP))
        XCTAssertFalse(offer.hasUrgentAction)
    }

    func testDaemonDownMakesRepairUrgent() {
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            dashboard: dashboard(
                daemonStatus: "unknown",
                machineAvailable: false,
                issues: ["machine: The Ouro mailbox did not answer before the Workbench timeout."]
            ),
            agents: [agent("slugger")],
            bossRegistration: registration("slugger", status: .registered),
            registrationByAgentName: ["slugger": registration("slugger", status: .registered)]
        )

        let offer = status.controlOffer
        XCTAssertTrue(offer.isAvailable(.repairDaemon))
        XCTAssertTrue(offer.isUrgent(.repairDaemon))
        XCTAssertTrue(offer.hasUrgentAction)
    }

    func testDaemonRespondingButNotRunningMakesRepairUrgent() {
        // Machine read succeeded but the daemon reports a non-running status:
        // still not reachable, so repair should be offered urgently.
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            dashboard: dashboard(daemonStatus: "stopped"),
            agents: [agent("slugger")],
            bossRegistration: registration("slugger", status: .registered),
            registrationByAgentName: ["slugger": registration("slugger", status: .registered)]
        )

        XCTAssertFalse(status.daemon.isReachable)
        XCTAssertTrue(status.controlOffer.isUrgent(.repairDaemon))
    }

    func testNotRegisteredBossOffersRegisterUrgently() {
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            dashboard: dashboard(daemonStatus: "running"),
            agents: [agent("slugger")],
            bossRegistration: registration("slugger", status: .notRegistered),
            registrationByAgentName: ["slugger": registration("slugger", status: .notRegistered)]
        )

        let offer = status.controlOffer
        XCTAssertTrue(status.boss.mcpIsActionable)
        XCTAssertTrue(offer.isAvailable(.registerWorkbenchMCP))
        XCTAssertTrue(offer.isUrgent(.registerWorkbenchMCP))
        XCTAssertTrue(offer.hasUrgentAction)
    }

    func testNeedsUpdateBossOffersRegisterUrgently() {
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            dashboard: dashboard(daemonStatus: "running"),
            agents: [agent("slugger")],
            bossRegistration: registration("slugger", status: .needsUpdate),
            registrationByAgentName: ["slugger": registration("slugger", status: .needsUpdate)]
        )

        let offer = status.controlOffer
        XCTAssertTrue(status.boss.mcpIsActionable)
        XCTAssertTrue(offer.isAvailable(.registerWorkbenchMCP))
        XCTAssertTrue(offer.isUrgent(.registerWorkbenchMCP))
    }

    func testBossBundleMissingDoesNotOfferRegister() {
        // agentMissing / executableMissing / invalidConfig aren't one-click
        // fixable from the status view — registration would just fail — so the
        // Register action must be hidden rather than offered-and-doomed.
        for badStatus in [
            BossWorkbenchMCPRegistrationStatus.agentMissing,
            .executableMissing,
            .invalidConfig
        ] {
            let status = HarnessStatusBuilder().build(
                boss: BossAgentSelection(agentName: "ghost"),
                dashboard: dashboard(daemonStatus: "running"),
                agents: [agent("slugger")],
                bossRegistration: registration("ghost", status: badStatus),
                registrationByAgentName: ["slugger": registration("slugger", status: .registered)]
            )

            let offer = status.controlOffer
            XCTAssertFalse(
                status.boss.mcpIsActionable,
                "\(badStatus) should not be MCP-actionable"
            )
            XCTAssertFalse(
                offer.isAvailable(.registerWorkbenchMCP),
                "\(badStatus) should not offer Register"
            )
        }
    }

    func testDaemonDownAndUnregisteredBossOffersBothUrgently() {
        // The worst case: both actions are the operator's next steps.
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            dashboard: dashboard(
                daemonStatus: "unknown",
                machineAvailable: false,
                issues: ["machine: timeout"]
            ),
            agents: [agent("slugger")],
            bossRegistration: registration("slugger", status: .notRegistered),
            registrationByAgentName: ["slugger": registration("slugger", status: .notRegistered)]
        )

        let offer = status.controlOffer
        XCTAssertTrue(offer.isUrgent(.repairDaemon))
        XCTAssertTrue(offer.isUrgent(.registerWorkbenchMCP))
        XCTAssertEqual(
            HarnessControlAction.allCases.filter { offer.isUrgent($0) }.count,
            2
        )
    }

    func testPreFirstRefreshOffersRepairUrgently() {
        // No dashboard yet ⇒ daemon "not checked" ⇒ not reachable ⇒ repair
        // should already be urgent so the operator can kick the daemon.
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            dashboard: nil,
            agents: [],
            bossRegistration: nil
        )

        let offer = status.controlOffer
        XCTAssertTrue(offer.isUrgent(.repairDaemon))
        // Register requires a known-actionable MCP status; nil isn't actionable.
        XCTAssertFalse(offer.isAvailable(.registerWorkbenchMCP))
    }
}
