import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchBootstrapperTests: XCTestCase {
    func testBootstrapCreatesDefaultProjectAndTrustedP0Lanes() {
        let state = WorkbenchBootstrapper().bootstrappedState(
            from: WorkspaceState(),
            defaults: WorkbenchDefaults(projectName: "Workbench", projectRootPath: "/tmp/workbench")
        )

        XCTAssertEqual(state.projects.map(\.name), ["Workbench"])
        XCTAssertEqual(state.boss.agentName, "slugger")
        XCTAssertEqual(state.processEntries.count, 4)
        XCTAssertEqual(state.processEntries.first?.name, "Local Shell")
        XCTAssertEqual(state.processEntries.first?.kind, .shell)
        XCTAssertEqual(state.processEntries.first?.executable, "/bin/zsh")
        XCTAssertEqual(state.processEntries.first?.arguments, ["-l"])
        XCTAssertEqual(Set(state.processEntries.compactMap(\.agentKind)), [.claudeCode, .githubCopilotCLI, .openAICodex])
        XCTAssertTrue(state.processEntries.allSatisfy { $0.trust == .trusted })
        XCTAssertTrue(state.processEntries.allSatisfy(\.autoResume))
        XCTAssertTrue(state.processEntries.allSatisfy { $0.workingDirectory == "/tmp/workbench" })
    }

    func testBootstrapDoesNotDuplicateExistingAgentLane() {
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
        XCTAssertEqual(bootstrapped.processEntries.count, 4)
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
