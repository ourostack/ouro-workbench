import XCTest
@testable import OuroWorkbenchCore

/// #U17 — the two readiness systems (autonomy / TTFA popover and onboarding / opt-in wizard)
/// overlap on the boss/MCP-bridge condition. This suite pins that they can NEVER report a
/// contradictory verdict (state) or tone (severity / copy register) for the same fixture state,
/// because both now derive that one condition from `BossBridgeContract`.
final class BossBridgeContractTests: XCTestCase {
    // MARK: - The shared contract classifies the overlap once

    func testBossVerdictIsBlockerForInvalidBundleNameAndOkForValid() {
        XCTAssertEqual(BossBridgeContract.bossVerdict(agentName: "ouroboros").severity, .ok)
        XCTAssertEqual(BossBridgeContract.bossVerdict(agentName: "../bad").severity, .blocker)
    }

    func testBridgeVerdictSeverityMatchesRegistrationStatus() {
        XCTAssertEqual(BossBridgeContract.bridgeVerdict(nil).severity, .warning)
        XCTAssertEqual(BossBridgeContract.bridgeVerdict(registration(.registered)).severity, .ok)
        for status in [BossWorkbenchMCPRegistrationStatus.notRegistered, .needsUpdate, .agentMissing, .executableMissing, .invalidConfig, .toolsNotInjected] {
            XCTAssertEqual(
                BossBridgeContract.bridgeVerdict(registration(status)).severity,
                .blocker,
                "non-registered bridge status \(status) must be the loud register"
            )
        }
    }

    // MARK: - Both surfaces agree on the overlapping condition (the U17 pin)

    /// THE contradiction the backlog cites: for the SAME bridge state, the autonomy popover and the
    /// onboarding wizard must not disagree about whether the boss/bridge is a problem (one saying
    /// "blocked" while the other says "a couple of things need you" for the same cause). Driving both
    /// builders off `BossBridgeContract` makes the overlapping verdict identical in both surfaces.
    func testAutonomyAndOnboardingNeverContradictOnTheBridgeCondition() {
        let bridgeStatuses: [BossWorkbenchMCPRegistrationStatus?] = [
            nil, .registered, .notRegistered, .needsUpdate, .agentMissing, .executableMissing, .invalidConfig, .toolsNotInjected
        ]

        for status in bridgeStatuses {
            let snapshot = status.map { registration($0) }
            let contractSeverity = BossBridgeContract.bridgeVerdict(snapshot).severity

            // Autonomy surface: the `boss-mcp` check state IS the contract severity, 1:1.
            let autonomy = autonomyBridgeCheck(registration: snapshot)
            XCTAssertEqual(
                map(checkState: autonomy.state),
                contractSeverity,
                "autonomy boss-mcp state must equal the contract severity for \(String(describing: status))"
            )

            // Onboarding surface: a `.blocker` contract severity (and ONLY a blocker) surfaces the
            // `workbench-mcp` repair step; `.ok`/`.warning` surface none. So the two surfaces express
            // the SAME conclusion: "the bridge is a problem" iff the contract says blocker.
            let onboardingFlagsBridge = onboardingSurfacesBridgeStep(registration: snapshot)
            XCTAssertEqual(
                onboardingFlagsBridge,
                contractSeverity == .blocker,
                "onboarding must flag the bridge iff the contract is blocker for \(String(describing: status))"
            )

            // The headline cross-check: whenever the bridge is the loud register, neither surface may
            // render the calm "ready" verdict for it.
            if contractSeverity == .blocker {
                XCTAssertEqual(autonomy.state, .blocker)
                XCTAssertTrue(onboardingFlagsBridge, "onboarding cannot call a blocked bridge ready")
            }
        }
    }

    // MARK: - Helpers

    private func autonomyBridgeCheck(registration: BossWorkbenchMCPRegistrationSnapshot?) -> AutonomyReadinessCheck {
        let state = WorkbenchBootstrapper().bootstrappedState(
            from: WorkspaceState(
                boss: BossAgentSelection(agentName: "ouroboros"),
                projects: [WorkbenchProject(name: "Workbench", rootPath: "/tmp/workbench")]
            )
        )
        let snapshot = AutonomyReadinessBuilder().build(
            state: state,
            summary: WorkspaceSummarizer().summarize(state),
            mcpRegistration: registration,
            executableHealth: [:],
            bossWatchIsEnabled: true
        )
        return snapshot.checks.first { $0.id == "boss-mcp" }!
    }

    private func onboardingSurfacesBridgeStep(registration: BossWorkbenchMCPRegistrationSnapshot?) -> Bool {
        let readiness = WorkbenchOnboardingAdvisor().readiness(
            boss: BossAgentSelection(agentName: "slugger"),
            agents: [
                OuroAgentRecord(
                    name: "slugger",
                    bundlePath: "/tmp/slugger.ouro",
                    configPath: "/tmp/slugger.ouro/agent.json",
                    status: .ready,
                    detail: "ready",
                    humanFacing: OuroAgentLane(provider: "minimax", model: "MiniMax-M2.7"),
                    agentFacing: OuroAgentLane(provider: "openai-codex", model: "gpt-5.5")
                )
            ],
            mcpRegistration: registration,
            providerChecks: [
                "outward": OnboardingProviderCheckResult(lane: "outward", state: .passed, detail: "ok"),
                "inner": OnboardingProviderCheckResult(lane: "inner", state: .passed, detail: "ok")
            ]
        )
        return readiness.repairSteps.contains { $0.id == "workbench-mcp" }
    }

    private func map(checkState: AutonomyReadinessCheckState) -> BossBridgeContract.Severity {
        switch checkState {
        case .ok: return .ok
        case .warning: return .warning
        case .blocker: return .blocker
        }
    }

    private func registration(_ status: BossWorkbenchMCPRegistrationStatus) -> BossWorkbenchMCPRegistrationSnapshot {
        BossWorkbenchMCPRegistrationSnapshot(
            agentName: "slugger",
            serverName: "ouro_workbench",
            commandPath: "/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP",
            agentConfigPath: "/tmp/slugger.ouro/agent.json",
            status: status,
            detail: status.rawValue
        )
    }
}
