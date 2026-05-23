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
        XCTAssertEqual(state.processEntries.count, 3)
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
        XCTAssertEqual(bootstrapped.processEntries.count, 3)
    }
}
