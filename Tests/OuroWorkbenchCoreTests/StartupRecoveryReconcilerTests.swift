import XCTest
@testable import OuroWorkbenchCore

final class StartupRecoveryReconcilerTests: XCTestCase {
    func testStartupReclassifiesInFlightRunsAsNeedingRecovery() {
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
        let running = ProcessRun(entryId: entry.id, pid: 123, status: .running)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [running])

        let reconciled = StartupRecoveryReconciler().reconcile(state)

        XCTAssertEqual(reconciled.processRuns.first?.status, .needsRecovery)
        XCTAssertNil(reconciled.processRuns.first?.pid)
        XCTAssertEqual(reconciled.processEntries.first?.attention, .needsBossReview)
        XCTAssertEqual(reconciled.processEntries.first?.lastSummary, "Codex needs startup recovery")
    }

    func testStartupLeavesExitedRunsExited() {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Claude",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "claude",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        let exited = ProcessRun(entryId: entry.id, pid: nil, status: .exited, exitCode: 0)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [exited])

        let reconciled = StartupRecoveryReconciler().reconcile(state)

        XCTAssertEqual(reconciled.processRuns.first?.status, .exited)
        XCTAssertEqual(reconciled.processRuns.first?.exitCode, 0)
        XCTAssertEqual(reconciled.processEntries.first?.attention, .idle)
    }
}
