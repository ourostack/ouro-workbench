import XCTest
@testable import OuroWorkbenchCore

final class AutonomyReadinessTests: XCTestCase {
    func testReadyWhenBossBridgeAgentRecoveryAndWatchAreClear() {
        let state = stateWithAgentTerminals()
        let snapshot = buildSnapshot(state: state, bossWatchIsEnabled: true)

        XCTAssertEqual(snapshot.state, .ready)
        XCTAssertEqual(snapshot.blockerCount, 0)
        XCTAssertEqual(snapshot.warningCount, 0)

        let appended = snapshot.appending(AutonomyReadinessCheck(id: "extra", label: "Extra", detail: "Warn", state: .warning))
        XCTAssertEqual(appended.label, snapshot.label)
        XCTAssertEqual(appended.state, .attention)
        XCTAssertEqual(appended.checks.last?.id, "extra")
    }

    func testInvalidBossAndUncheckedBridgeBlockOrWarn() {
        var state = stateWithAgentTerminals()
        state.boss = BossAgentSelection(agentName: "../bad")

        let invalidBoss = buildSnapshot(state: state, registration: nil, bossWatchIsEnabled: true)

        XCTAssertEqual(invalidBoss.check(id: "boss")?.state, .blocker)
        XCTAssertEqual(invalidBoss.check(id: "boss-mcp")?.state, .warning)
        XCTAssertEqual(invalidBoss.state, AutonomyReadinessState.blocked)
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

    func testExecutableMissingAndInvalidBridgeStatusesBlockReadiness() {
        for status in [BossWorkbenchMCPRegistrationStatus.executableMissing, .invalidConfig] {
            let snapshot = buildSnapshot(
                state: stateWithAgentTerminals(),
                registration: Self.registration(status: status),
                bossWatchIsEnabled: true
            )

            XCTAssertEqual(snapshot.check(id: "boss-mcp")?.state, .blocker)
        }
    }

    func testUntrustedAgentsUsePluralCopyAndBlock() {
        var state = stateWithAgentTerminals()
        for index in state.processEntries.indices {
            state.processEntries[index].trust = .untrusted
        }

        let snapshot = buildSnapshot(state: state, bossWatchIsEnabled: true)

        XCTAssertEqual(snapshot.check(id: "terminal-trust")?.state, .blocker)
        XCTAssertTrue(snapshot.check(id: "terminal-trust")?.detail.contains("are not trusted") == true)
    }

    func testDetectedAgentWithDisabledAutoResumeBlocksReadiness() {
        var state = stateWithAgentTerminals()
        let codexIndex = state.processEntries.firstIndex { $0.agentKind == .openAICodex }!
        state.processEntries[codexIndex].autoResume = false

        let snapshot = buildSnapshot(state: state, bossWatchIsEnabled: true)

        XCTAssertEqual(snapshot.state, .blocked)
        XCTAssertEqual(snapshot.check(id: "terminal-resume")?.state, .blocker)
    }

    func testMultipleDisabledAutoResumeAgentsUsePluralCopy() {
        var state = stateWithAgentTerminals()
        for index in state.processEntries.indices {
            state.processEntries[index].autoResume = false
        }

        let snapshot = buildSnapshot(state: state, bossWatchIsEnabled: true)

        XCTAssertTrue(snapshot.check(id: "terminal-resume")?.detail.contains("have auto-resume disabled") == true)
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

    func testExecutableCheckWarnsWhenHealthHasNotBeenChecked() {
        let snapshot = buildSnapshot(state: stateWithAgentTerminals(), executableHealth: [:], bossWatchIsEnabled: true)

        XCTAssertEqual(snapshot.check(id: "executables")?.state, .warning)
        XCTAssertTrue(snapshot.check(id: "executables")?.detail.contains("Executable health has not been checked") == true)
    }

    func testShellExecutableHealthIsCheckedWhenNoAgentTerminalsExist() {
        let project = WorkbenchProject(name: "Project", rootPath: "/Users/example/project")
        let shell = ProcessEntry(projectId: project.id, name: "Shell", kind: .shell, executable: "/bin/zsh", workingDirectory: project.rootPath)
        let state = WorkspaceState(boss: BossAgentSelection(agentName: "ouroboros"), projects: [project], processEntries: [shell])

        let snapshot = buildSnapshot(state: state, executableHealth: [shell.id: ExecutableHealth(executable: "/bin/zsh", status: .available, detail: "ok")], bossWatchIsEnabled: true)

        XCTAssertEqual(snapshot.check(id: "executables")?.detail, "Configured terminal commands are available.")
    }

    func testManualRecoveryBlocksReadiness() {
        var state = stateWithAgentTerminals()
        let codex = state.processEntries.first { $0.agentKind == .openAICodex }!
        state.processRuns.append(ProcessRun(entryId: codex.id, status: .manualActionNeeded))

        let snapshot = buildSnapshot(state: state, bossWatchIsEnabled: true)

        XCTAssertEqual(snapshot.state, .blocked)
        XCTAssertEqual(snapshot.check(id: "recovery")?.state, .blocker)
    }

    func testPluralManualRecoveryAndSortedEntryNames() {
        var state = stateWithAgentTerminals()
        for entry in state.processEntries {
            state.processRuns.append(ProcessRun(entryId: entry.id, status: .manualActionNeeded))
            if let index = state.processEntries.firstIndex(where: { $0.id == entry.id }) {
                state.processEntries[index].trust = .untrusted
            }
        }

        let snapshot = buildSnapshot(state: state, bossWatchIsEnabled: true)

        XCTAssertEqual(snapshot.check(id: "recovery")?.state, .blocker)
        XCTAssertTrue(snapshot.check(id: "terminal-trust")?.detail.contains("Claude, Codex are not trusted") == true)
    }

    func testManualResumePresetBlocksReadiness() {
        let state = stateWithAgentTerminals()
        let manualPreset = TerminalAgentPreset(
            id: .claudeCode,
            displayName: "Manual Claude",
            executable: "claude",
            defaultArguments: [],
            yoloArguments: [],
            resumeStrategy: ResumeStrategy(kind: .manual, notes: "manual")
        )
        let snapshot = AutonomyReadinessBuilder(presetProvider: { kind in
            kind == .claudeCode ? manualPreset : TerminalAgentPresets.preset(for: kind)
        }).build(
            state: state,
            summary: WorkspaceSummarizer().summarize(state),
            mcpRegistration: Self.registration(status: .registered),
            executableHealth: availableHealth(for: state),
            bossWatchIsEnabled: true
        )

        XCTAssertEqual(snapshot.check(id: "terminal-resume")?.state, .blocker)
        XCTAssertTrue(snapshot.check(id: "terminal-resume")?.detail.contains("no automatic resume strategy") == true)
    }

    func testPluralManualResumeAndCustomAgentWithoutPresetBranches() {
        var state = stateWithAgentTerminals()
        state.processEntries.append(ProcessEntry(
            projectId: state.projects[0].id,
            name: "Custom Agent",
            kind: .terminalAgent,
            agentKind: .custom,
            executable: "custom",
            workingDirectory: "/tmp/workbench",
            autoResume: true
        ))
        let manualPreset = TerminalAgentPreset(
            id: .claudeCode,
            displayName: "Manual",
            executable: "agent",
            defaultArguments: [],
            yoloArguments: [],
            resumeStrategy: ResumeStrategy(kind: .manual, notes: "manual")
        )
        let snapshot = AutonomyReadinessBuilder(presetProvider: { kind in
            switch kind {
            case .claudeCode, .openAICodex:
                return TerminalAgentPreset(
                    id: kind,
                    displayName: manualPreset.displayName,
                    executable: manualPreset.executable,
                    defaultArguments: [],
                    yoloArguments: [],
                    resumeStrategy: manualPreset.resumeStrategy
                )
            default:
                return nil
            }
        }).build(
            state: state,
            summary: WorkspaceSummarizer().summarize(state),
            mcpRegistration: Self.registration(status: .registered),
            executableHealth: availableHealth(for: state),
            bossWatchIsEnabled: true
        )

        XCTAssertTrue(snapshot.check(id: "terminal-resume")?.detail.contains("Claude, Codex have no automatic resume strategy") == true)
    }

    func testUnavailableExecutableWithoutDetailFallsBackToNotChecked() {
        let state = stateWithAgentTerminals()
        let first = state.processEntries.first { $0.name == "Claude" }!
        var health = availableHealth(for: state)
        health[first.id] = ExecutableHealth(executable: first.executable, status: .missing, detail: "No executable configured.")
        let snapshot = buildSnapshot(
            state: state,
            executableHealth: health,
            bossWatchIsEnabled: true
        )

        XCTAssertEqual(snapshot.check(id: "executables")?.state, .blocker)
        XCTAssertTrue(snapshot.check(id: "executables")?.detail.contains("No executable configured") == true)
    }

    func testQueuedRecoveryWarnsWithPluralCopy() {
        var state = stateWithAgentTerminals()
        for entry in state.processEntries {
            state.processRuns.append(ProcessRun(entryId: entry.id, status: .needsRecovery))
        }

        let snapshot = buildSnapshot(state: state, bossWatchIsEnabled: true)

        XCTAssertEqual(snapshot.check(id: "recovery")?.state, .warning)
        XCTAssertTrue(snapshot.check(id: "recovery")?.detail.contains("restart action") == true)
    }

    func testNoAgentTerminalsIsAttentiveButNotBlocked() {
        let state = bootstrappedState()
        let snapshot = buildSnapshot(state: state, bossWatchIsEnabled: true)

        XCTAssertEqual(snapshot.state, .attention)
        XCTAssertEqual(snapshot.check(id: "terminal-trust")?.state, .warning)
        XCTAssertEqual(snapshot.check(id: "terminal-resume")?.state, .warning)
    }

    func testShellOnlyExecutableCheckSortsActiveShellEntriesByName() {
        let project = WorkbenchProject(name: "Project", rootPath: "/Users/example/project")
        let zed = ProcessEntry(projectId: project.id, name: "zed shell", kind: .shell, executable: "zed", workingDirectory: project.rootPath)
        let alpha = ProcessEntry(projectId: project.id, name: "Alpha shell", kind: .shell, executable: "alpha", workingDirectory: project.rootPath)
        let state = WorkspaceState(boss: BossAgentSelection(agentName: "ouroboros"), projects: [project], processEntries: [zed, alpha])
        let snapshot = buildSnapshot(
            state: state,
            executableHealth: [
                zed.id: ExecutableHealth(executable: "zed", status: .missing, detail: "zed missing"),
                alpha.id: ExecutableHealth(executable: "alpha", status: .missing, detail: "alpha missing")
            ],
            bossWatchIsEnabled: true
        )

        XCTAssertEqual(snapshot.check(id: "executables")?.state, .blocker)
        XCTAssertEqual(snapshot.check(id: "executables")?.detail, "Alpha shell: alpha missing zed shell: zed missing")
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
        registration: BossWorkbenchMCPRegistrationSnapshot? = AutonomyReadinessTests.registration(status: .registered),
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
