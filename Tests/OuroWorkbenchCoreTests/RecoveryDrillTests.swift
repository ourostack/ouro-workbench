import XCTest
@testable import OuroWorkbenchCore

final class RecoveryDrillTests: XCTestCase {
    func testDrillSimulatesRestartAndPlansRecovery() {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let codex = ProcessEntry(
            projectId: project.id,
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        let run = ProcessRun(entryId: codex.id, pid: 123, status: .running)
        let state = WorkspaceState(projects: [project], processEntries: [codex], processRuns: [run])

        let result = RecoveryDrill().run(state: state, now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(result.oneLineStatus, "1 recovery action after simulated restart")
        XCTAssertEqual(result.items.first?.entryName, "Codex")
        XCTAssertEqual(result.items.first?.beforeStatus, .running)
        XCTAssertEqual(result.items.first?.afterStatus, .needsRecovery)
        XCTAssertEqual(result.items.first?.action, .autoResume)
        XCTAssertEqual(result.items.first?.reason, "OpenAI Codex can continue the most recent session in this working directory")
    }

    func testDrillReportsManualRecoveryForUntrustedInFlightEntry() {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Untrusted",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            arguments: ["-lc", "danger"],
            workingDirectory: "/repo",
            trust: .untrusted,
            autoResume: true
        )
        let run = ProcessRun(entryId: entry.id, status: .waitingForInput)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])

        let result = RecoveryDrill().run(state: state)

        XCTAssertEqual(result.items.first?.beforeStatus, .waitingForInput)
        XCTAssertEqual(result.items.first?.afterStatus, .needsRecovery)
        XCTAssertEqual(result.items.first?.action, .manualActionNeeded)
        XCTAssertEqual(result.items.first?.reason, "entry is not trusted")
    }

    func testDrillLeavesExitedRunsAlone() {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Shell",
            kind: .shell,
            executable: "/bin/zsh",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        let run = ProcessRun(entryId: entry.id, status: .exited)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])

        let result = RecoveryDrill().run(state: state)

        XCTAssertEqual(result.oneLineStatus, "0 recovery actions after simulated restart")
        XCTAssertEqual(result.items.first?.beforeStatus, .exited)
        XCTAssertEqual(result.items.first?.afterStatus, .exited)
        XCTAssertEqual(result.items.first?.action, .noAction)
    }

    func testDrillDoesNotMutateInputState() {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        let run = ProcessRun(entryId: entry.id, pid: 123, status: .running)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])

        _ = RecoveryDrill().run(state: state)

        XCTAssertEqual(state.processRuns.first?.status, .running)
        XCTAssertEqual(state.processRuns.first?.pid, 123)
        XCTAssertEqual(state.processEntries.first?.attention, .idle)
    }
}
