import XCTest
@testable import OuroWorkbenchCore

final class CommandPlannerTests: XCTestCase {
    func testLaunchPlanUsesEntryCommandAndTranscriptPath() throws {
        let paths = WorkbenchPaths(rootURL: URL(fileURLWithPath: "/tmp/OuroWorkbenchTests", isDirectory: true))
        let project = WorkbenchProject(name: "Project", rootPath: "/tmp/project")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            arguments: ["--yolo"],
            workingDirectory: "/tmp/project",
            trust: .trusted,
            autoResume: true
        )

        let plan = try WorkbenchCommandPlanner(paths: paths).launchPlan(for: entry)

        XCTAssertEqual(plan.entryId, entry.id)
        XCTAssertEqual(plan.executable, "codex")
        XCTAssertEqual(plan.arguments, ["--yolo"])
        XCTAssertEqual(plan.workingDirectory, "/tmp/project")
        XCTAssertTrue(plan.transcriptPath?.contains(entry.id.uuidString) == true)
        XCTAssertTrue(plan.transcriptPath?.contains(plan.runId.uuidString) == true)
        XCTAssertEqual(plan.displayCommand, "codex --yolo")
        XCTAssertEqual(plan.launchInvocation.executable, "/usr/bin/env")
        XCTAssertEqual(plan.launchInvocation.arguments, ["codex", "--yolo"])
        XCTAssertEqual(plan.launchInvocation.execName, "codex")
    }

    func testNativeResumePlanSubstitutesSessionId() throws {
        let project = WorkbenchProject(name: "Project", rootPath: "/tmp/project")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Claude Code",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "claude",
            arguments: ["--dangerously-skip-permissions"],
            workingDirectory: "/tmp/project",
            trust: .trusted,
            autoResume: true
        )
        let run = ProcessRun(
            entryId: entry.id,
            status: .needsRecovery,
            terminalSessionId: "claude-session-123"
        )

        let plan = try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: run, action: .autoResume)

        XCTAssertEqual(plan.executable, "claude")
        XCTAssertEqual(plan.arguments, ["--dangerously-skip-permissions", "--resume", "claude-session-123"])
        XCTAssertEqual(plan.recoveryAction, .autoResume)
    }

    func testAbsoluteExecutablesLaunchDirectly() {
        let plan = TerminalCommandPlan(
            entryId: UUID(),
            executable: "/bin/zsh",
            arguments: ["-l"],
            workingDirectory: "/tmp",
            reason: "test"
        )

        XCTAssertEqual(plan.launchInvocation.executable, "/bin/zsh")
        XCTAssertEqual(plan.launchInvocation.arguments, ["-l"])
        XCTAssertEqual(plan.launchInvocation.execName, "zsh")
    }

    func testNativeResumeFallsBackToLatestSessionCommand() throws {
        let project = WorkbenchProject(name: "Project", rootPath: "/tmp/project")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            arguments: ["--yolo"],
            workingDirectory: "/tmp/project",
            trust: .trusted,
            autoResume: true
        )

        let plan = try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: nil, action: .autoResume)

        XCTAssertEqual(plan.executable, "codex")
        XCTAssertEqual(plan.arguments, ["--yolo", "resume", "--last"])
        XCTAssertEqual(plan.recoveryAction, .autoResume)
        XCTAssertEqual(plan.reason, "resume Codex using latest-session fallback")
    }

    func testCheckpointRespawnIncludesRecoveryPrompt() throws {
        let project = WorkbenchProject(name: "Project", rootPath: "/tmp/project")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "GitHub Copilot CLI",
            kind: .terminalAgent,
            agentKind: .githubCopilotCLI,
            executable: "copilot",
            arguments: ["--yolo"],
            workingDirectory: "/tmp/project",
            trust: .trusted,
            autoResume: true
        )
        let run = ProcessRun(
            entryId: entry.id,
            status: .needsRecovery,
            transcriptPath: "/tmp/transcript.log"
        )

        let plan = try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: run, action: .respawn)

        XCTAssertEqual(plan.executable, "copilot")
        XCTAssertEqual(plan.arguments.first, "--yolo")
        XCTAssertEqual(plan.recoveryAction, .respawn)
        XCTAssertEqual(plan.reason, "respawn GitHub Copilot CLI with checkpoint recovery prompt")
        XCTAssertTrue(plan.arguments.last?.contains("Recover this Ouro Workbench terminal-agent session") == true)
        XCTAssertTrue(plan.arguments.last?.contains("/tmp/transcript.log") == true)
    }
}
