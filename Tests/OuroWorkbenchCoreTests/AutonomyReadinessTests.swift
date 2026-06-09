import XCTest
@testable import OuroWorkbenchCore

final class AutonomyReadinessTests: XCTestCase {
    func testReadyWhenBossBridgeAgentRecoveryAndWatchAreClear() {
        let state = stateWithAgentTerminals()
        let snapshot = buildSnapshot(state: state, bossWatchIsEnabled: true)

        XCTAssertEqual(snapshot.state, .ready)
        XCTAssertEqual(snapshot.blockerCount, 0)
        XCTAssertEqual(snapshot.warningCount, 0)
    }

    func testPausedBossWatchMakesAutonomyAttentiveButUsable() {
        let state = stateWithAgentTerminals()
        let snapshot = buildSnapshot(state: state, bossWatchIsEnabled: false)

        XCTAssertEqual(snapshot.state, .attention)
        XCTAssertEqual(snapshot.check(id: "boss-watch")?.state, .warning)
    }

    func testMissingBossBridgeBlocksHandsOffOperation() {
        let state = stateWithAgentTerminals()
        let snapshot = buildSnapshot(
            state: state,
            registration: Self.registration(status: .notRegistered),
            bossWatchIsEnabled: true
        )

        XCTAssertEqual(snapshot.state, .blocked)
        XCTAssertEqual(snapshot.check(id: "boss-mcp")?.state, .blocker)
    }

    func testDetectedAgentWithDisabledAutoResumeBlocksReadiness() {
        var state = stateWithAgentTerminals()
        let codexIndex = state.processEntries.firstIndex { $0.agentKind == .openAICodex }!
        state.processEntries[codexIndex].autoResume = false

        let snapshot = buildSnapshot(state: state, bossWatchIsEnabled: true)

        XCTAssertEqual(snapshot.state, .blocked)
        XCTAssertEqual(snapshot.check(id: "terminal-resume")?.state, .blocker)
    }

    func testMissingDetectedAgentExecutableBlocksReadiness() {
        let state = stateWithAgentTerminals()
        let codex = state.processEntries.first { $0.agentKind == .openAICodex }!
        var health = availableHealth(for: state)
        health[codex.id] = ExecutableHealth(
            executable: codex.executable,
            status: .missing,
            detail: "codex was not found on PATH."
        )

        let snapshot = buildSnapshot(state: state, executableHealth: health, bossWatchIsEnabled: true)

        XCTAssertEqual(snapshot.state, .blocked)
        XCTAssertEqual(snapshot.check(id: "executables")?.state, .blocker)
    }

    func testManualRecoveryBlocksReadiness() {
        var state = stateWithAgentTerminals()
        let codex = state.processEntries.first { $0.agentKind == .openAICodex }!
        state.processRuns.append(ProcessRun(entryId: codex.id, status: .manualActionNeeded))

        let snapshot = buildSnapshot(state: state, bossWatchIsEnabled: true)

        XCTAssertEqual(snapshot.state, .blocked)
        XCTAssertEqual(snapshot.check(id: "recovery")?.state, .blocker)
    }

    func testNoAgentTerminalsIsAttentiveButNotBlocked() {
        let state = bootstrappedState()
        let snapshot = buildSnapshot(state: state, bossWatchIsEnabled: true)

        XCTAssertEqual(snapshot.state, .attention)
        XCTAssertEqual(snapshot.check(id: "terminal-trust")?.state, .warning)
        XCTAssertEqual(snapshot.check(id: "terminal-resume")?.state, .warning)
    }

    private func bootstrappedState() -> WorkspaceState {
        WorkbenchBootstrapper().bootstrappedState(
            // Explicit resolved boss — the default is now unresolved (empty), and an
            // unresolved boss correctly blocks autonomy; these tests exercise the
            // OTHER readiness dimensions given a real boss.
            from: WorkspaceState(boss: BossAgentSelection(agentName: "ouroboros")),
            defaults: WorkbenchDefaults(projectName: "Workbench", projectRootPath: "/tmp/workbench")
        )
    }

    private func stateWithAgentTerminals() -> WorkspaceState {
        let project = WorkbenchProject(name: "Workbench", rootPath: "/tmp/workbench")
        return WorkbenchBootstrapper().bootstrappedState(
            from: WorkspaceState(
                boss: BossAgentSelection(agentName: "ouroboros"),
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

    private func buildSnapshot(
        state: WorkspaceState,
        registration: BossWorkbenchMCPRegistrationSnapshot = AutonomyReadinessTests.registration(status: .registered),
        executableHealth: [UUID: ExecutableHealth]? = nil,
        bossWatchIsEnabled: Bool
    ) -> AutonomyReadinessSnapshot {
        AutonomyReadinessBuilder().build(
            state: state,
            summary: WorkspaceSummarizer().summarize(state),
            mcpRegistration: registration,
            executableHealth: executableHealth ?? availableHealth(for: state),
            bossWatchIsEnabled: bossWatchIsEnabled
        )
    }

    private func availableHealth(for state: WorkspaceState) -> [UUID: ExecutableHealth] {
        Dictionary(uniqueKeysWithValues: state.processEntries.map { entry in
            (
                entry.id,
                ExecutableHealth(
                    executable: entry.executable,
                    resolvedPath: "/usr/bin/\(entry.executable)",
                    status: .available,
                    detail: "Found /usr/bin/\(entry.executable)."
                )
            )
        })
    }

    private static func registration(status: BossWorkbenchMCPRegistrationStatus) -> BossWorkbenchMCPRegistrationSnapshot {
        BossWorkbenchMCPRegistrationSnapshot(
            agentName: "slugger",
            serverName: "ouro_workbench",
            commandPath: "/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP",
            agentConfigPath: "/Users/ari/AgentBundles/slugger.ouro/agent.json",
            status: status,
            detail: status.rawValue
        )
    }
}

private extension AutonomyReadinessSnapshot {
    func check(id: String) -> AutonomyReadinessCheck? {
        checks.first { $0.id == id }
    }
}
