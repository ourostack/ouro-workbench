import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchBootstrapperTests: XCTestCase {
    func testDefaultBootstrapCreatesUnsortedWorkspaceWithoutLocalShell() throws {
        let state = WorkbenchBootstrapper().bootstrappedState(from: WorkspaceState())

        XCTAssertEqual(state.projects.map(\.name), [WorkbenchSurfacePolicy.setupWorkspaceName])
        XCTAssertFalse(state.projects.contains { $0.name == "This Mac" })
        XCTAssertTrue(state.processEntries.isEmpty)
        XCTAssertNil(state.selectedEntryId)
    }

    func testBootstrapCreatesCustomProjectWithoutLocalShell() throws {
        let state = WorkbenchBootstrapper().bootstrappedState(
            from: WorkspaceState(),
            defaults: WorkbenchDefaults(projectName: "Workbench", projectRootPath: "/tmp/workbench")
        )

        XCTAssertEqual(state.projects.map(\.name), ["Workbench"])
        XCTAssertFalse(state.projects.contains { $0.name == "This Mac" })
        // Bootstrap leaves the boss UNRESOLVED (empty). The boss is never
        // hardcoded — it is resolved from the installed-agent inventory at runtime
        // (BossAutoResolution): 0 agents → acquisition, 1 → auto-adopt, >1 → human
        // choice. A hardcoded default would land first-run on a non-existent agent.
        XCTAssertEqual(state.boss.agentName, "")
        XCTAssertTrue(state.processEntries.isEmpty)
        XCTAssertNil(state.selectedEntryId)
        XCTAssertEqual(state.projects.first?.rootPath, "/tmp/workbench")
    }

    func testBootstrapSetupModeCreatesUnsortedWorkspaceWithoutLocalShell() throws {
        let state = WorkbenchBootstrapper().bootstrappedState(
            from: WorkspaceState(),
            defaults: .firstRunSetup(projectRootPath: "/tmp/workbench")
        )

        XCTAssertEqual(state.projects.map(\.name), ["Unsorted Sessions"])
        XCTAssertFalse(state.projects.contains { $0.name == "This Mac" })
        XCTAssertTrue(state.processEntries.isEmpty)
        XCTAssertNil(state.selectedEntryId)
        XCTAssertEqual(state.projects.first?.rootPath, "/tmp/workbench")
    }

    func testBootstrapPreservesExistingAgentTerminalWithoutCreatingFixedScaffolds() {
        let project = WorkbenchProject(name: "Existing", rootPath: "/tmp/existing")
        let existing = ProcessEntry(
            projectId: project.id,
            name: "Claude Code",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "claude",
            workingDirectory: ""
        )
        let state = WorkspaceState(projects: [project], processEntries: [existing])

        let bootstrapped = WorkbenchBootstrapper().bootstrappedState(from: state)

        XCTAssertEqual(bootstrapped.processEntries.filter { $0.agentKind == .claudeCode }.count, 1)
        XCTAssertEqual(bootstrapped.processEntries.count, 1)
        XCTAssertFalse(bootstrapped.processEntries.contains { $0.name == "Local Shell" })
        XCTAssertEqual(bootstrapped.processEntries.first { $0.id == existing.id }?.workingDirectory, "/tmp/existing")
    }

    func testBootstrapRemovesUntouchedGeneratedAgentScaffolds() {
        let project = WorkbenchProject(name: "Existing", rootPath: "/tmp/existing")
        let copilot = ProcessEntry(
            projectId: project.id,
            name: "GitHub Copilot CLI",
            kind: .terminalAgent,
            agentKind: .githubCopilotCLI,
            executable: "gh",
            arguments: ["copilot", "--", "--yolo"],
            workingDirectory: "/tmp/existing",
            lastSummary: "Configured GitHub Copilot CLI lane"
        )
        let codex = ProcessEntry(
            projectId: project.id,
            name: "OpenAI Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            arguments: ["--yolo"],
            workingDirectory: "/tmp/existing",
            lastSummary: "Configured OpenAI Codex lane"
        )
        let demo = ProcessEntry(
            projectId: project.id,
            name: "Demo Agent",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            arguments: ["-lc", "echo hello from demo"],
            workingDirectory: "/tmp/existing",
            lastSummary: "Custom terminal session: echo hello from demo"
        )
        let state = WorkspaceState(
            selectedEntryId: codex.id,
            projects: [project],
            processEntries: [copilot, codex, demo]
        )

        let bootstrapped = WorkbenchBootstrapper().bootstrappedState(from: state)

        XCTAssertFalse(bootstrapped.processEntries.contains { $0.id == copilot.id })
        XCTAssertFalse(bootstrapped.processEntries.contains { $0.id == codex.id })
        XCTAssertFalse(bootstrapped.processEntries.contains { $0.id == demo.id })
        XCTAssertNil(bootstrapped.selectedEntryId)
        XCTAssertTrue(bootstrapped.processEntries.isEmpty)
    }

    func testBootstrapKeepsGeneratedAgentScaffoldsWithRuns() {
        let project = WorkbenchProject(name: "Existing", rootPath: "/tmp/existing")
        let codex = ProcessEntry(
            projectId: project.id,
            name: "OpenAI Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            arguments: ["--yolo"],
            workingDirectory: "/tmp/existing",
            lastSummary: "Configured OpenAI Codex lane"
        )
        let run = ProcessRun(entryId: codex.id, status: .exited)
        let state = WorkspaceState(projects: [project], processEntries: [codex], processRuns: [run])

        let bootstrapped = WorkbenchBootstrapper().bootstrappedState(from: state)

        XCTAssertTrue(bootstrapped.processEntries.contains { $0.id == codex.id })
        XCTAssertEqual(bootstrapped.processEntries.count, 1)
        XCTAssertFalse(bootstrapped.processEntries.contains { $0.name == "Local Shell" })
    }

    func testBootstrapKeepsGeneratedAgentScaffoldsWithActionLog() {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let preset = TerminalAgentPresets.preset(for: .claudeCode)!
        let generated = ProcessEntry(
            projectId: project.id,
            name: preset.displayName,
            kind: .terminalAgent,
            agentKind: preset.id,
            executable: preset.executable,
            workingDirectory: "/repo",
            lastSummary: "Configured \(preset.displayName) lane"
        )
        let action = WorkbenchActionLogEntry(
            source: "test",
            action: "launch",
            targetEntryId: generated.id,
            targetName: generated.name,
            result: "launched",
            succeeded: true
        )

        let bootstrapped = WorkbenchBootstrapper().bootstrappedState(
            from: WorkspaceState(projects: [project], processEntries: [generated], actionLog: [action])
        )

        XCTAssertEqual(bootstrapped.processEntries.map(\.id), [generated.id])
        XCTAssertFalse(bootstrapped.processEntries.contains { $0.name == "Local Shell" })
    }

    func testBootstrapDetectsKnownCLIFromShellWrappedImportedTerminal() throws {
        let project = WorkbenchProject(name: "Existing", rootPath: "/tmp/existing")
        let existing = ProcessEntry(
            projectId: project.id,
            name: "Codex Scratch",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            arguments: ["-lc", "codex --yolo"],
            workingDirectory: "/tmp/existing",
            trust: .trusted,
            autoResume: true
        )
        let state = WorkspaceState(projects: [project], processEntries: [existing])

        let bootstrapped = WorkbenchBootstrapper().bootstrappedState(from: state)
        let detected = try XCTUnwrap(bootstrapped.processEntries.first { $0.name == "Codex Scratch" })

        XCTAssertEqual(detected.id, existing.id)
        XCTAssertEqual(detected.agentKind, .openAICodex)
        XCTAssertEqual(detected.executable, "/bin/zsh")
        XCTAssertEqual(detected.arguments, ["-lc", "codex --yolo"])
        XCTAssertEqual(detected.trust, .trusted)
        XCTAssertEqual(detected.autoResume, true)
    }

    func testBootstrapDeduplicatesEntriesSharingAnID() {
        // A malformed / torn state file with two entries under the same id must
        // not trap a downstream `Dictionary(uniqueKeysWithValues:)` keyed on the
        // entry id (which would crash the long-lived MCP server). Bootstrap keeps
        // the first occurrence per id.
        let project = WorkbenchProject(name: "Existing", rootPath: "/tmp/existing")
        let sharedId = UUID()
        let first = ProcessEntry(
            id: sharedId,
            projectId: project.id,
            name: "First",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "claude",
            workingDirectory: "/tmp/existing"
        )
        let duplicate = ProcessEntry(
            id: sharedId,
            projectId: project.id,
            name: "Duplicate",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            workingDirectory: "/tmp/existing"
        )
        let state = WorkspaceState(
            projects: [project],
            processEntries: [first, duplicate]
        )

        let bootstrapped = WorkbenchBootstrapper().bootstrappedState(from: state)

        // Exactly one entry per id (no trap), and it's the first occurrence.
        XCTAssertEqual(bootstrapped.processEntries.filter { $0.id == sharedId }.count, 1)
        let kept = bootstrapped.processEntries.first { $0.id == sharedId }
        XCTAssertEqual(kept?.name, "First")
        // Ids are unique across the whole entry list, so any id-keyed dictionary
        // a consumer builds (executableHealth / gitStatus / search) is safe.
        let ids = bootstrapped.processEntries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testBootstrapPreservesPersistedLocalShellWithoutRepairingIt() {
        let project = WorkbenchProject(name: "Existing", rootPath: "/tmp/existing")
        let existing = ProcessEntry(
            projectId: project.id,
            name: "Local Shell",
            kind: .shell,
            executable: "/tmp/not-zsh",
            arguments: ["-c", "echo nope"],
            workingDirectory: "/tmp/existing",
            trust: .untrusted,
            autoResume: false
        )
        let state = WorkspaceState(projects: [project], processEntries: [existing])

        let bootstrapped = WorkbenchBootstrapper().bootstrappedState(from: state)

        XCTAssertEqual(bootstrapped.processEntries.filter { $0.kind == .shell && $0.name == "Local Shell" }.count, 1)
        XCTAssertEqual(bootstrapped.processEntries.first?.id, existing.id)
        XCTAssertEqual(bootstrapped.processEntries.first?.executable, "/tmp/not-zsh")
        XCTAssertEqual(bootstrapped.processEntries.first?.arguments, ["-c", "echo nope"])
        XCTAssertEqual(bootstrapped.processEntries.first?.workingDirectory, "/tmp/existing")
        XCTAssertEqual(bootstrapped.processEntries.first?.trust, .untrusted)
        XCTAssertEqual(bootstrapped.processEntries.first?.autoResume, false)
        XCTAssertNil(bootstrapped.processEntries.first?.lastSummary)
    }

    func testBootstrapLeavesStateAloneWhenDefaultProjectCannotBeCreated() {
        let state = WorkbenchBootstrapper().bootstrappedState(from: WorkspaceState(), makeDefaultProject: { nil })

        XCTAssertTrue(state.projects.isEmpty)
        XCTAssertTrue(state.processEntries.isEmpty)
    }
}
