import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchBootstrapperTests: XCTestCase {
    func testBootstrapCreatesDefaultProjectAndLocalShellOnly() throws {
        let state = WorkbenchBootstrapper().bootstrappedState(
            from: WorkspaceState(),
            defaults: WorkbenchDefaults(projectName: "Workbench", projectRootPath: "/tmp/workbench")
        )

        XCTAssertEqual(state.projects.map(\.name), ["Workbench"])
        XCTAssertEqual(state.boss.agentName, "slugger")
        XCTAssertEqual(state.processEntries.count, 1)
        XCTAssertEqual(state.processEntries.first?.name, "Local Shell")
        XCTAssertEqual(state.processEntries.first?.kind, .shell)
        XCTAssertEqual(state.processEntries.first?.executable, "/bin/zsh")
        XCTAssertEqual(state.processEntries.first?.arguments, ["-l"])
        XCTAssertTrue(state.processEntries.allSatisfy { $0.trust == .trusted })
        XCTAssertTrue(state.processEntries.allSatisfy(\.autoResume))
        XCTAssertTrue(state.processEntries.allSatisfy { $0.workingDirectory == "/tmp/workbench" })
    }

    func testBootstrapPreservesExistingAgentTerminalWithoutCreatingFixedScaffolds() {
        let project = WorkbenchProject(name: "Existing", rootPath: "/tmp/existing")
        let existing = ProcessEntry(
            projectId: project.id,
            name: "Claude Code",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "claude",
            workingDirectory: "/tmp/existing"
        )
        let state = WorkspaceState(projects: [project], processEntries: [existing])

        let bootstrapped = WorkbenchBootstrapper().bootstrappedState(from: state)

        XCTAssertEqual(bootstrapped.processEntries.filter { $0.agentKind == .claudeCode }.count, 1)
        XCTAssertEqual(bootstrapped.processEntries.count, 2)
    }

    func testBootstrapRemovesUntouchedLegacyAgentScaffolds() {
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
        XCTAssertEqual(bootstrapped.processEntries.map { $0.name }, ["Local Shell"])
    }

    func testBootstrapKeepsLegacyAgentScaffoldsWithRuns() {
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
        XCTAssertEqual(bootstrapped.processEntries.count, 2)
    }

    func testBootstrapDetectsKnownCLIFromShellWrappedLegacyTerminal() throws {
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

    func testBootstrapRepairsAndDoesNotDuplicateExistingLocalShell() {
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
        XCTAssertEqual(bootstrapped.processEntries.first?.executable, "/bin/zsh")
        XCTAssertEqual(bootstrapped.processEntries.first?.arguments, ["-l"])
        XCTAssertEqual(bootstrapped.processEntries.first?.trust, .trusted)
        XCTAssertEqual(bootstrapped.processEntries.first?.autoResume, true)
        XCTAssertTrue(BuiltInWorkbenchSessions.isAutoLaunchableLocalShell(bootstrapped.processEntries[0]))
    }
}
