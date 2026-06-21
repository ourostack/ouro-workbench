import XCTest
@testable import OuroWorkbenchCore

/// The pure availability derivation (#U20): the MCP sensor must read the SAME runtime
/// fix-availability gate the operator's popover uses, so a blocker with no live fix reads
/// degraded on both surfaces. These tests pin each field to the workspace inputs that drive it.
final class AutonomyRemediationAvailabilityBuilderTests: XCTestCase {
    private let builder = AutonomyRemediationAvailabilityBuilder()

    func testAllGreenWorkspaceHasNoLiveFixWorkExceptWatchAndLogin() {
        let state = stateWithAgentTerminals(bossWatchEnabled: true)
        let availability = build(state: state, registration: registration(.registered))

        XCTAssertFalse(availability.hasUntrustedTerminals)
        XCTAssertFalse(availability.hasResumableDisabledTerminals)
        XCTAssertFalse(availability.mcpRegistrationActionable, "a registered bridge isn't actionable")
        XCTAssertFalse(availability.hasRecoverableEntries)
        XCTAssertFalse(availability.bossWatchDisabled, "watch on → no watch fix to do")
        XCTAssertTrue(availability.loginItemActionable, "inert default — open-at-login isn't an MCP check")
    }

    func testUntrustedTerminalIsLiveTrustWork() {
        var state = stateWithAgentTerminals(bossWatchEnabled: true)
        state.processEntries[0].trust = .untrusted

        XCTAssertTrue(build(state: state, registration: registration(.registered)).hasUntrustedTerminals)
    }

    func testDisabledAutoResumeOnAutomaticStrategyAgentIsLiveResumeWork() {
        var state = stateWithAgentTerminals(bossWatchEnabled: true)
        // Claude/Codex presets carry automatic resume strategies; disabling the toggle is fixable.
        for index in state.processEntries.indices {
            state.processEntries[index].autoResume = false
        }

        XCTAssertTrue(build(state: state, registration: registration(.registered)).hasResumableDisabledTerminals)
    }

    func testActionableBridgeStatusesFlipMcpActionable() {
        let state = stateWithAgentTerminals(bossWatchEnabled: true)
        XCTAssertTrue(build(state: state, registration: registration(.notRegistered)).mcpRegistrationActionable)
        XCTAssertTrue(build(state: state, registration: registration(.needsUpdate)).mcpRegistrationActionable)
        XCTAssertFalse(build(state: state, registration: registration(.executableMissing)).mcpRegistrationActionable)
        XCTAssertFalse(build(state: state, registration: nil).mcpRegistrationActionable, "no registration → not actionable")
    }

    func testAutoRecoverablePlanIsLiveRecoverWorkButManualIsNot() {
        var state = stateWithAgentTerminals(bossWatchEnabled: true)
        let codex = state.processEntries.first { $0.agentKind == .openAICodex }!
        state.processRuns.append(ProcessRun(entryId: codex.id, status: .needsRecovery))
        XCTAssertTrue(build(state: state).hasRecoverableEntries, "needsRecovery → auto-resume plan is recoverable")

        var manualState = stateWithAgentTerminals(bossWatchEnabled: true)
        let claude = manualState.processEntries.first { $0.agentKind == .claudeCode }!
        manualState.processRuns.append(ProcessRun(entryId: claude.id, status: .manualActionNeeded))
        manualState.processEntries[manualState.processEntries.firstIndex(where: { $0.id == claude.id })!].trust = .untrusted
        XCTAssertFalse(build(state: manualState).hasRecoverableEntries, "manual-only recovery isn't a live Recover button")
    }

    func testPausedWatchIsLiveWatchWork() {
        let state = stateWithAgentTerminals(bossWatchEnabled: false)
        XCTAssertTrue(build(state: state).bossWatchDisabled)
    }

    func testUndetectableAgentTerminalIsNotCountedAsResumableWork() {
        // An auto-resume-off terminal agent whose harness can't be detected (no agentKind, an
        // unrecognized executable) has no preset to flip — it's degraded, not a one-tap resume fix.
        let project = WorkbenchProject(name: "Workbench", rootPath: "/tmp/workbench")
        let mystery = ProcessEntry(
            projectId: project.id,
            name: "Mystery",
            kind: .terminalAgent,
            executable: "mysteryagent",
            workingDirectory: "/tmp/workbench",
            trust: .trusted,
            autoResume: false
        )
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "ouroboros"),
            projects: [project],
            processEntries: [mystery]
        )

        XCTAssertFalse(build(state: state).hasResumableDisabledTerminals)
    }

    // MARK: - helpers

    private func build(
        state: WorkspaceState,
        registration: BossWorkbenchMCPRegistrationSnapshot? = nil
    ) -> AutonomyRemediationAvailability {
        builder.availability(
            state: state,
            summary: WorkspaceSummarizer().summarize(state),
            mcpRegistration: registration
        )
    }

    private func stateWithAgentTerminals(bossWatchEnabled: Bool) -> WorkspaceState {
        let project = WorkbenchProject(name: "Workbench", rootPath: "/tmp/workbench")
        return WorkbenchBootstrapper().bootstrappedState(
            from: WorkspaceState(
                boss: BossAgentSelection(agentName: "ouroboros"),
                bossWatchEnabled: bossWatchEnabled,
                projects: [project],
                processEntries: [
                    ProcessEntry(
                        projectId: project.id,
                        name: "Claude",
                        kind: .terminalAgent,
                        agentKind: .claudeCode,
                        executable: "claude",
                        arguments: ["--dangerously-skip-permissions"],
                        workingDirectory: "/tmp/workbench",
                        trust: .trusted,
                        autoResume: true
                    ),
                    ProcessEntry(
                        projectId: project.id,
                        name: "Codex",
                        kind: .terminalAgent,
                        agentKind: .openAICodex,
                        executable: "codex",
                        arguments: ["--yolo"],
                        workingDirectory: "/tmp/workbench",
                        trust: .trusted,
                        autoResume: true
                    )
                ]
            )
        )
    }

    private func registration(_ status: BossWorkbenchMCPRegistrationStatus) -> BossWorkbenchMCPRegistrationSnapshot {
        BossWorkbenchMCPRegistrationSnapshot(
            agentName: "slugger",
            serverName: "ouro_workbench",
            commandPath: "/path/OuroWorkbenchMCP",
            agentConfigPath: "/path/slugger.ouro/agent.json",
            status: status,
            detail: status.rawValue
        )
    }
}
