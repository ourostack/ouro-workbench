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
        XCTAssertEqual(plan.persistentSessionName, PersistentTerminalSession.sessionName(for: entry.id))
        XCTAssertEqual(plan.launchInvocation.executable, "/usr/bin/screen")
        XCTAssertEqual(plan.launchInvocation.arguments, [
            "-U",
            "-T", "xterm-256color",
            "-h", "0",
            "-e", "^]]",
            "-D",
            "-RR",
            "-S", PersistentTerminalSession.sessionName(for: entry.id),
            "--",
            "/usr/bin/env",
            "codex",
            "--yolo",
        ])
        XCTAssertEqual(plan.launchInvocation.execName, "screen")
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

    func testNativeResumePlanDropsStaleClaudeResumeSessionArgument() throws {
        let project = WorkbenchProject(name: "Project", rootPath: "/tmp/project")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Claude Code",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "claude",
            arguments: ["--dangerously-skip-permissions", "--resume", "stale-session"],
            workingDirectory: "/tmp/project",
            trust: .trusted,
            autoResume: true
        )
        let run = ProcessRun(
            entryId: entry.id,
            status: .needsRecovery,
            terminalSessionId: "fresh-session"
        )

        let plan = try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: run, action: .autoResume)

        XCTAssertEqual(plan.arguments, ["--dangerously-skip-permissions", "--resume", "fresh-session"])
    }

    func testNativeResumePlanDropsStaleCodexResumeSessionArgument() throws {
        let project = WorkbenchProject(name: "Project", rootPath: "/tmp/project")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            arguments: ["--yolo", "resume", "stale-session"],
            workingDirectory: "/tmp/project",
            trust: .trusted,
            autoResume: true
        )
        let run = ProcessRun(
            entryId: entry.id,
            status: .needsRecovery,
            terminalSessionId: "fresh-session"
        )

        let plan = try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: run, action: .autoResume)

        XCTAssertEqual(plan.arguments, ["--yolo", "resume", "fresh-session"])
    }

    func testNativeResumePlanPreservesNonStrategyArgumentsNamedResume() throws {
        let project = WorkbenchProject(name: "Project", rootPath: "/tmp/project")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Claude Code",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "claude",
            arguments: ["--label", "resume"],
            workingDirectory: "/tmp/project",
            trust: .trusted,
            autoResume: true
        )
        let run = ProcessRun(
            entryId: entry.id,
            status: .needsRecovery,
            terminalSessionId: "fresh-session"
        )

        let plan = try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: run, action: .autoResume)

        XCTAssertEqual(plan.arguments, ["--label", "resume", "--resume", "fresh-session"])
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

    func testPersistentAbsoluteExecutableLaunchesInsideScreenSession() {
        let entryId = UUID()
        let plan = TerminalCommandPlan(
            entryId: entryId,
            executable: "/bin/zsh",
            arguments: ["-l"],
            workingDirectory: "/tmp",
            persistentSessionName: PersistentTerminalSession.sessionName(for: entryId),
            reason: "test"
        )

        XCTAssertEqual(plan.launchInvocation.executable, "/usr/bin/screen")
        XCTAssertEqual(Array(plan.launchInvocation.arguments.suffix(3)), ["--", "/bin/zsh", "-l"])
        XCTAssertEqual(PersistentTerminalSession.terminateArguments(sessionName: "session"), ["-S", "session", "-X", "quit"])
        XCTAssertEqual(PersistentTerminalSession.listArguments(), ["-ls"])
    }

    func testPersistentTerminalSessionDetectsListedSessionNames() {
        let output = """
        There is a screen on:
            12345.ouro-wb-abc123\t(Detached)
        1 Socket in /var/folders/example.
        """

        XCTAssertTrue(PersistentTerminalSession.listOutput(output, contains: "ouro-wb-abc123"))
        XCTAssertFalse(PersistentTerminalSession.listOutput(output, contains: "ouro-wb-missing"))
        XCTAssertFalse(PersistentTerminalSession.listOutput(output, contains: "ouro-wb-abc12"))
    }

    func testPersistentTerminalSessionPrefersBundledScreenExecutable() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OuroWorkbenchBundle-\(UUID().uuidString)")
            .appendingPathComponent("Ouro Workbench.app")
        let executableURL = bundleURL
            .appendingPathComponent(PersistentTerminalSession.bundledExecutableRelativePath)
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        defer {
            try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent())
        }

        XCTAssertEqual(
            PersistentTerminalSession.executablePath(bundleURL: bundleURL),
            executableURL.path
        )
    }

    func testPersistentTerminalSessionFallsBackToSystemScreenWhenBundleToolIsMissing() {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissingOuroWorkbenchBundle-\(UUID().uuidString)")
            .appendingPathComponent("Ouro Workbench.app")

        XCTAssertEqual(
            PersistentTerminalSession.executablePath(bundleURL: bundleURL),
            PersistentTerminalSession.systemFallbackExecutable
        )
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

    func testNativeResumeForShellWrappedDetectedAgentDoesNotReuseShellWrapper() throws {
        let project = WorkbenchProject(name: "Project", rootPath: "/tmp/project")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Claude Scratch",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "/bin/zsh",
            arguments: ["-lc", "claude --dangerously-skip-permissions"],
            workingDirectory: "/tmp/project",
            trust: .trusted,
            autoResume: true
        )

        let plan = try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: nil, action: .autoResume)

        XCTAssertEqual(plan.executable, "claude")
        XCTAssertEqual(plan.arguments, ["--dangerously-skip-permissions", "--continue"])
        XCTAssertEqual(plan.reason, "resume Claude Scratch using latest-session fallback")
    }

    func testCheckpointRespawnIncludesRecoveryPrompt() throws {
        let project = WorkbenchProject(name: "Project", rootPath: "/tmp/project")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "GitHub Copilot CLI",
            kind: .terminalAgent,
            agentKind: .githubCopilotCLI,
            executable: "gh",
            arguments: ["copilot", "--", "--yolo"],
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

        XCTAssertEqual(plan.executable, "gh")
        XCTAssertEqual(Array(plan.arguments.prefix(3)), ["copilot", "--", "--yolo"])
        XCTAssertEqual(plan.recoveryAction, .respawn)
        XCTAssertEqual(plan.reason, "respawn GitHub Copilot CLI with checkpoint recovery prompt")
        XCTAssertTrue(plan.arguments.last?.contains("Recover this Ouro Workbench terminal-agent session") == true)
        XCTAssertTrue(plan.arguments.last?.contains("/tmp/transcript.log") == true)
    }

    func testCheckpointRespawnDetectsShellWrappedCopilot() throws {
        let project = WorkbenchProject(name: "Project", rootPath: "/tmp/project")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Copilot Scratch",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            arguments: ["-lc", "gh copilot -- --yolo"],
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

        XCTAssertEqual(plan.executable, "/bin/zsh")
        XCTAssertEqual(plan.arguments[0], "-lc")
        XCTAssertEqual(plan.recoveryAction, .respawn)
        XCTAssertEqual(plan.reason, "respawn Copilot Scratch with checkpoint recovery prompt")
        XCTAssertTrue(plan.arguments.last?.contains("Recover this Ouro Workbench terminal-agent session") == true)
    }

    func testCheckpointRespawnCoversGenericTerminalAgents() throws {
        let project = WorkbenchProject(name: "Project", rootPath: "/tmp/project")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Generic TUI",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            arguments: ["-lc", "aider --yes"],
            workingDirectory: "/tmp/project",
            trust: .trusted,
            autoResume: true
        )
        let run = ProcessRun(
            entryId: entry.id,
            status: .needsRecovery,
            transcriptPath: "/tmp/generic-transcript.log"
        )

        let plan = try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: run, action: .respawn)

        XCTAssertEqual(plan.executable, "/bin/zsh")
        XCTAssertEqual(plan.arguments[0], "-lc")
        XCTAssertEqual(plan.recoveryAction, .respawn)
        XCTAssertEqual(plan.reason, "respawn Generic TUI with checkpoint recovery prompt")
        XCTAssertTrue(plan.arguments.last?.contains("Recover this Ouro Workbench terminal-agent session") == true)
        XCTAssertTrue(plan.arguments.last?.contains("/tmp/generic-transcript.log") == true)
    }
}
