import XCTest
@testable import OuroWorkbenchCore

final class RecoveryPlannerTests: XCTestCase {
    func testClaudeCodeWithSessionIdAutoResumes() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
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
        let run = ProcessRun(
            entryId: entry.id,
            status: .needsRecovery,
            terminalSessionId: "claude-session-123"
        )
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])

        let plan = RecoveryPlanner().planRecovery(for: state)

        XCTAssertEqual(plan, [
            RecoveryPlan(
                entryId: entry.id,
                runId: run.id,
                action: .autoResume,
                reason: "Claude Code has native resume metadata"
            )
        ])
    }

    func testCopilotRespawnsFromCheckpointUntilNativeResumeIsVerified() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Copilot",
            kind: .terminalAgent,
            agentKind: .githubCopilotCLI,
            executable: "copilot",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])

        let plan = RecoveryPlanner().planRecovery(for: state)

        XCTAssertEqual(plan.first?.action, .respawn)
        XCTAssertEqual(plan.first?.reason, "GitHub Copilot CLI will reopen from persisted checkpoint context")
    }

    func testCustomTerminalAgentRespawnsFromCheckpointContext() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Custom TUI",
            kind: .terminalAgent,
            agentKind: .custom,
            executable: "/bin/zsh",
            arguments: ["-lc", "aider --yes"],
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])

        let plan = RecoveryPlanner().planRecovery(for: state)

        XCTAssertEqual(plan.first?.action, .respawn)
        XCTAssertEqual(plan.first?.reason, "custom terminal agent will reopen from persisted checkpoint context")
    }

    func testClaudeCodeWithoutSessionIdUsesLatestSessionFallback() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
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
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])

        let plan = RecoveryPlanner().planRecovery(for: state)

        XCTAssertEqual(plan.first?.action, .autoResume)
        XCTAssertEqual(plan.first?.reason, "Claude Code can continue the most recent session in this working directory")
    }

    func testUntrustedEntriesNeverAutoResume() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Untrusted",
            kind: .command,
            executable: "rm",
            arguments: ["-rf", "/tmp/example"],
            workingDirectory: "/repo",
            trust: .untrusted,
            autoResume: true
        )
        let state = WorkspaceState(projects: [project], processEntries: [entry])

        let plan = RecoveryPlanner().planRecovery(for: state)

        XCTAssertEqual(plan.first?.action, .noAction)
        XCTAssertEqual(plan.first?.reason, "no prior run to recover")
    }

    func testUntrustedNeedsRecoveryRequiresManualAction() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Untrusted",
            kind: .command,
            executable: "rm",
            arguments: ["-rf", "/tmp/example"],
            workingDirectory: "/repo",
            trust: .untrusted,
            autoResume: true
        )
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])

        let plan = RecoveryPlanner().planRecovery(for: state)

        XCTAssertEqual(plan.first?.action, .manualActionNeeded)
        XCTAssertEqual(plan.first?.reason, "entry is not trusted")
    }

    func testExitedRunDoesNotRecover() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
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
        let run = ProcessRun(entryId: entry.id, status: .exited, terminalSessionId: "claude-session-123")
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])

        let plan = RecoveryPlanner().planRecovery(for: state)

        XCTAssertEqual(plan.first?.action, .noAction)
        XCTAssertEqual(plan.first?.reason, "latest run status is exited")
    }

    func testArchivedEntryDoesNotRecoverEvenWithNeedsRecoveryRun() {
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Archived",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            arguments: ["-lc", "aider --yes"],
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true,
            isArchived: true
        )
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])

        let plan = RecoveryPlanner().planRecovery(for: state)

        XCTAssertEqual(plan.first?.action, .noAction)
        XCTAssertEqual(plan.first?.reason, "entry is archived")
    }
}
