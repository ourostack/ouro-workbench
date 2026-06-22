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
            ],
            // A config-only `.ready` is no longer counted as ready without a live
            // verdict; a `.working` outward check is what earns the green.
            outwardVerdicts: ["slugger": .working, "boss-b": .working]
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
            ],
            outwardVerdicts: ["slugger": .working, "boss-b": .working]
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
            registrationByAgentName: ["slugger": registration("slugger", status: .needsUpdate)],
            outwardVerdicts: ["slugger": .working]
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
            registrationByAgentName: ["slugger": registration("slugger", status: .registered)],
            outwardVerdicts: ["slugger": .working]
        )

        XCTAssertTrue(status.agents.hasUnready)
        XCTAssertEqual(status.agents.readyCount, 1)
        XCTAssertEqual(status.agents.total, 2)
        // Daemon up + boss reachable, but an unready agent keeps it at attention.
        XCTAssertEqual(status.overallState, .attention)
    }

    // MARK: - Live-verdict honesty (the harness false-green fix)

    /// A config-`.ready` agent whose live OUTWARD check came back `.unauthorized`
    /// (expired token) must NOT count as ready anywhere: the per-entry `isReady`
    /// is false, it's excluded from `readyCount`, drives `hasUnready`, and the
    /// headline + overallState reflect the degraded agent. This is the bug the
    /// harness surface used to hide behind a config-only green.
    func testExpiredTokenAgentIsNotReadyDespiteConfigReady() {
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            dashboard: dashboard(daemonStatus: "running"),
            agents: [agent("slugger"), agent("helper")],
            bossRegistration: registration("slugger", status: .registered),
            registrationByAgentName: [
                "slugger": registration("slugger", status: .registered),
                "helper": registration("helper", status: .registered)
            ],
            // slugger's token is alive; helper's outward check returned 401.
            outwardVerdicts: ["slugger": .working, "helper": .unauthorized]
        )

        let helper = status.agents.entries.first { $0.name == "helper" }
        XCTAssertEqual(helper?.verdict, .unauthorized)
        XCTAssertEqual(helper?.liveReadiness, .authExpired)
        XCTAssertEqual(helper?.isReady, false)

        // Rollups are now honest: only slugger counts as ready.
        XCTAssertEqual(status.agents.readyCount, 1)
        XCTAssertEqual(status.agents.total, 2)
        XCTAssertTrue(status.agents.hasUnready)
        XCTAssertEqual(status.agents.summaryLine, "2 local, 1 ready")
        // Daemon up + boss reachable, but the expired agent keeps it at attention,
        // and the headline counts it out of the ready tally.
        XCTAssertEqual(status.overallState, .attention)
        XCTAssertEqual(status.headline, "Daemon up · 1 of 2 agents ready · boss slugger reachable")
    }

    /// A config-`.ready` agent that's still mid-check (a live probe is in flight,
    /// no verdict yet) is NOT ready — the surface shows "checking…", never a
    /// premature green. The in-flight flag overrides the absence of a verdict.
    func testInFlightAgentIsNotReady() {
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            dashboard: dashboard(daemonStatus: "running"),
            agents: [agent("slugger")],
            bossRegistration: registration("slugger", status: .registered),
            registrationByAgentName: ["slugger": registration("slugger", status: .registered)],
            // No verdict yet, but a check is in flight for slugger.
            checksInFlight: ["slugger"]
        )

        let slugger = status.agents.entries.first { $0.name == "slugger" }
        XCTAssertNil(slugger?.verdict)
        XCTAssertEqual(slugger?.isChecking, true)
        XCTAssertEqual(slugger?.liveReadiness, .checking)
        XCTAssertEqual(slugger?.isReady, false)
        XCTAssertEqual(status.agents.readyCount, 0)
        XCTAssertTrue(status.agents.hasUnready)
        // Boss bundle isn't confirmed-ready while its check is in flight, so the
        // boss isn't reachable yet either.
        XCTAssertFalse(status.boss.isReachable)
    }

    /// A config-`.ready` agent with no verdict and no in-flight check is
    /// `.unverified` — still NOT ready. A config-only `.ready` never earns green
    /// on its own (the whole point of the fix).
    func testConfigReadyWithoutAnyLiveCheckIsUnverifiedNotReady() {
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            dashboard: dashboard(daemonStatus: "running"),
            agents: [agent("slugger")],
            bossRegistration: registration("slugger", status: .registered),
            registrationByAgentName: ["slugger": registration("slugger", status: .registered)]
        )

        let slugger = status.agents.entries.first { $0.name == "slugger" }
        XCTAssertNil(slugger?.verdict)
        XCTAssertEqual(slugger?.isChecking, false)
        XCTAssertEqual(slugger?.liveReadiness, .unverified)
        XCTAssertEqual(slugger?.isReady, false)
        XCTAssertEqual(status.agents.readyCount, 0)
        XCTAssertTrue(status.agents.hasUnready)
    }

    /// Config problems dominate the live verdict: a `.disabled` bundle is never
    /// "ready" even if a stale `.working` verdict is somehow present. The honesty
    /// invariant resolves config-state first.
    func testConfigProblemDominatesStaleWorkingVerdict() {
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            dashboard: dashboard(daemonStatus: "running"),
            agents: [
                agent("slugger"),
                agent("retired", status: .disabled, detail: "disabled in agent.json")
            ],
            bossRegistration: registration("slugger", status: .registered),
            registrationByAgentName: ["slugger": registration("slugger", status: .registered)],
            // A leftover `.working` verdict for the now-disabled agent must NOT
            // resurrect it as ready.
            outwardVerdicts: ["slugger": .working, "retired": .working]
        )

        let retired = status.agents.entries.first { $0.name == "retired" }
        XCTAssertEqual(retired?.liveReadiness, .disabled)
        XCTAssertEqual(retired?.isReady, false)
        XCTAssertEqual(status.agents.readyCount, 1)
        XCTAssertTrue(status.agents.hasUnready)
    }

    /// The boss bundle's reachability keys off the SAME honest `isReady`: a boss
    /// whose outward check is `.unauthorized` is not bundle-ready, so the boss is
    /// not reachable even with the MCP registered and the daemon up.
    func testBossWithExpiredTokenIsNotReachable() {
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            dashboard: dashboard(daemonStatus: "running"),
            agents: [agent("slugger")],
            bossRegistration: registration("slugger", status: .registered),
            registrationByAgentName: ["slugger": registration("slugger", status: .registered)],
            outwardVerdicts: ["slugger": .unauthorized]
        )

        XCTAssertFalse(status.boss.bundleIsReady)
        XCTAssertFalse(status.boss.isReachable)
        XCTAssertEqual(status.boss.bundleText, "missing or not ready")
        XCTAssertEqual(status.overallState, .blocked)
        XCTAssertEqual(status.headline, "Boss slugger is not reachable")
    }

    /// The `liveReadiness` computed accessor folds the entry's own
    /// status/verdict/isChecking through the shared presentation seam, so the
    /// harness pill and the steady-state rows can never disagree.
    func testLiveReadinessComputedMatchesPresentationSeam() {
        let cases: [(OuroAgentBundleStatus, ProviderConnectionVerdict?, Bool, InstalledAgentRowPresentation.LiveReadiness)] = [
            (.ready, .working, false, .ready),
            (.ready, .unauthorized, false, .authExpired),
            (.ready, .vaultLocked, false, .vaultLocked),
            (.ready, .unreachable, false, .unreachable),
            (.ready, .indeterminate, false, .unverified),
            (.ready, nil, true, .checking),
            (.ready, nil, false, .unverified),
            (.disabled, .working, false, .disabled),
            (.missingConfig, nil, false, .missingConfig),
            (.invalidConfig, nil, false, .invalidConfig)
        ]
        for (status, verdict, isChecking, expected) in cases {
            let entry = HarnessAgentEntry(
                name: "a",
                status: status,
                detail: "d",
                isSelectedBoss: false,
                verdict: verdict,
                isChecking: isChecking
            )
            XCTAssertEqual(
                entry.liveReadiness, expected,
                "status=\(status) verdict=\(String(describing: verdict)) isChecking=\(isChecking)"
            )
            XCTAssertEqual(entry.isReady, expected == .ready)
        }
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

    func testDaemonUnknownTextForEmptyStatusModeAndVersion() {
        let daemon = HarnessDaemonStatus(status: "", mode: "", version: "")

        XCTAssertFalse(daemon.isReachable)
        XCTAssertEqual(daemon.statusText, "unknown")
        XCTAssertEqual(daemon.modeText, "unknown")
        XCTAssertEqual(daemon.versionText, "unknown")
        XCTAssertEqual(daemon.state, .attention)
    }

    func testAgentInventorySummaryAndEntryID() {
        // A config-`.ready` boss earns "ready" only with a live `.working` verdict.
        let entry = HarnessAgentEntry(name: "slugger", status: .ready, detail: "ready", isSelectedBoss: true, verdict: .working)
        let inventory = HarnessAgentInventory(entries: [entry, HarnessAgentEntry(name: "helper", status: .disabled, detail: "off", isSelectedBoss: false)])

        XCTAssertEqual(entry.id, "slugger")
        XCTAssertTrue(entry.isReady)
        XCTAssertEqual(entry.liveReadiness, .ready)
        XCTAssertEqual(inventory.summaryLine, "2 local, 1 ready")
        XCTAssertEqual(inventory.selectedBoss?.id, "slugger")
    }

    func testBossReachabilityUnknownAndNonActionableMCPStatuses() {
        let unknown = HarnessBossReachability(agentName: "slugger", bundleIsReady: true, mcpStatus: nil)
        XCTAssertEqual(unknown.state, .attention)
        XCTAssertEqual(unknown.mcpStatusText, "unknown")

        let cases: [(BossWorkbenchMCPRegistrationStatus, String)] = [
            (.agentMissing, "agent bundle missing"),
            (.executableMissing, "install app first"),
            (.invalidConfig, "config issue"),
        ]
        for (status, text) in cases {
            let boss = HarnessBossReachability(agentName: "slugger", bundleIsReady: true, mcpStatus: status)
            XCTAssertEqual(boss.mcpStatusText, text)
            XCTAssertEqual(boss.state, .blocked)
        }

        XCTAssertEqual(HarnessBossReachability(agentName: "slugger", bundleIsReady: true, mcpStatus: .needsUpdate).state, .attention)
        XCTAssertEqual(HarnessBossReachability(agentName: "slugger", bundleIsReady: false, mcpStatus: .needsUpdate).state, .blocked)
    }

    func testMachineIssueFallbackWhenNoMachinePrefixedIssueExists() {
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            dashboard: dashboard(
                daemonStatus: "unknown",
                machineAvailable: false,
                issues: ["needs-me: timeout"]
            ),
            agents: [],
            bossRegistration: nil
        )

        XCTAssertEqual(status.daemon.statusText, "unreachable (mailbox did not answer)")
    }

    // MARK: - Empty inventory headline is grammatical

    func testSingleAgentHeadlineIsSingular() {
        let status = HarnessStatusBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            dashboard: dashboard(daemonStatus: "running"),
            agents: [agent("slugger")],
            bossRegistration: registration("slugger", status: .registered),
            registrationByAgentName: ["slugger": registration("slugger", status: .registered)],
            outwardVerdicts: ["slugger": .working]
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
