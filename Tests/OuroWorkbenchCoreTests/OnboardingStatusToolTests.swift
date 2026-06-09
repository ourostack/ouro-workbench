import XCTest
@testable import OuroWorkbenchCore

final class OnboardingStatusToolTests: XCTestCase {
    func testRendererEmitsStateOrderedStepsActorTagsAndAuditHistory() {
        let readiness = OnboardingReadiness(
            state: .needsRepair,
            headline: "Repair slugger",
            detail: "Workbench found slugger, but it needs setup before it can be a reliable boss.",
            selectedBossName: "slugger",
            repairSteps: [
                OnboardingRepairStep(
                    id: "repair-agent-config",
                    actor: .agentRunnable,
                    title: "Repair slugger",
                    detail: "bundle config drift",
                    command: ["ouro", "repair", "--agent", "slugger"]
                ),
                OnboardingRepairStep(
                    id: "request-provider-config",
                    actor: .humanRequired,
                    title: "Connect a provider",
                    detail: "Workbench opens a setup form.",
                    command: ["ouro", "connect", "providers", "--agent", "slugger"]
                )
            ]
        )

        let rendered = OnboardingReadinessReportRenderer().render(readiness)

        // State + selected boss.
        XCTAssertTrue(rendered.contains("state: needsRepair"))
        XCTAssertTrue(rendered.contains("boss: slugger"))
        XCTAssertTrue(rendered.contains("Repair slugger"))

        // Ordered repair steps preserve order (step 1 before step 2).
        let firstStepRange = try? XCTUnwrap(rendered.range(of: "repair-agent-config"))
        let secondStepRange = try? XCTUnwrap(rendered.range(of: "request-provider-config"))
        XCTAssertNotNil(firstStepRange)
        XCTAssertNotNil(secondStepRange)
        if let firstStepRange, let secondStepRange {
            XCTAssertTrue(firstStepRange.lowerBound < secondStepRange.lowerBound, "repair steps must render in order")
        }
        // Steps are numbered so the agent can narrate an ordered remediation.
        XCTAssertTrue(rendered.contains("1."))
        XCTAssertTrue(rendered.contains("2."))

        // Actor tags appear per step.
        XCTAssertTrue(rendered.contains("agent-runnable"))
        XCTAssertTrue(rendered.contains("human-required"))

        // Audit history: the raw `ouro` verbs appear in an audit lane (recovery-truth surface).
        XCTAssertTrue(rendered.lowercased().contains("audit"))
        XCTAssertTrue(rendered.contains("ouro repair --agent slugger"))
        XCTAssertTrue(rendered.contains("ouro connect providers --agent slugger"))
    }

    func testRendererHandlesReadyStateWithNoSteps() {
        let readiness = OnboardingReadiness(
            state: .ready,
            headline: "slugger is ready",
            detail: "All set.",
            selectedBossName: "slugger",
            repairSteps: []
        )

        let rendered = OnboardingReadinessReportRenderer().render(readiness)

        XCTAssertTrue(rendered.contains("state: ready"))
        XCTAssertTrue(rendered.contains("slugger is ready"))
        // No remediation needed: the report says so rather than emitting an empty list.
        XCTAssertTrue(rendered.lowercased().contains("no remediation"))
    }

    func testRendererSurfacesDaemonDownState() {
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
            mcpRegistration: BossWorkbenchMCPRegistrationSnapshot(
                agentName: "slugger",
                serverName: "ouro-workbench",
                commandPath: "/tmp/mcp",
                agentConfigPath: "/tmp/slugger.ouro/agent.json",
                status: .registered,
                detail: "registered"
            ),
            daemonLiveness: .down
        )

        let rendered = OnboardingReadinessReportRenderer().render(readiness)
        XCTAssertTrue(rendered.contains("state: needsDaemon"))
        XCTAssertTrue(rendered.contains("ensure-daemon"))
        XCTAssertTrue(rendered.contains("ouro up"))
    }

    func testToolDescriptionCarriesNarrateFromNextReadContract() {
        let description = OnboardingReadinessReportRenderer.toolDescription

        // It must tell the agent to narrate from the NEXT status read, not from a
        // request-action enqueue ack (the action queue is async / 2s-polled).
        let lowered = description.lowercased()
        XCTAssertTrue(lowered.contains("workbench_onboarding_status"))
        XCTAssertTrue(lowered.contains("next"))
        XCTAssertTrue(lowered.contains("workbench_request_action"))
        XCTAssertTrue(
            lowered.contains("enqueue") || lowered.contains("ack") || lowered.contains("acknowled"),
            "description must warn against narrating from the enqueue acknowledgement"
        )
        XCTAssertTrue(lowered.contains("narrat"))
    }

    func testToolNameConstantMatchesPublishedTool() {
        XCTAssertEqual(OnboardingReadinessReportRenderer.toolName, "workbench_onboarding_status")
    }
}
