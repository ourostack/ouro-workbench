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
            "-h", "10000",
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

    /// Reattach (`-D -RR`) must keep a non-empty scrollback buffer so the operator
    /// sees the agent's prior output, not an empty screen. `screen`'s `-h` flag sets
    /// the scrollback history depth; `-h 0` discards it. Assert `-h` is immediately
    /// followed by a non-zero count.
    func testReattachPreservesScrollback() {
        let args = PersistentTerminalSession.attachOrCreateArguments(
            sessionName: "ouro-wb-abc",
            command: ["/usr/bin/env", "codex"]
        )

        let flagIndex = try? XCTUnwrap(args.firstIndex(of: "-h"))
        let index = flagIndex ?? -1
        XCTAssertGreaterThanOrEqual(index, 0, "expected a -h scrollback flag")
        XCTAssertLessThan(index + 1, args.count, "expected a value after -h")
        let value = Int(args[index + 1])
        XCTAssertNotNil(value, "expected a numeric -h value, got \(args[index + 1])")
        XCTAssertGreaterThan(value ?? 0, 0, "scrollback depth must be non-zero on reattach")
    }

    func testLaunchPlanThrowsOnEmptyExecutable() {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Broken",
            kind: .terminalAgent,
            executable: "   ",
            workingDirectory: "/tmp"
        )
        XCTAssertThrowsError(try WorkbenchCommandPlanner().launchPlan(for: entry)) { error in
            guard case CommandPlanningError.emptyExecutable(let name) = error else {
                return XCTFail("expected emptyExecutable, got \(error)")
            }
            XCTAssertEqual(name, "Broken")
        }
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

    // MARK: - F4 end-to-end: back-filled session id drives explicit-id resume

    /// (a) The F4 fix end-to-end: a `.needsRecovery` run whose `terminalSessionId`
    /// is back-filled by `SessionIdBackfill` from a scanned record renders an
    /// explicit-id resume (`claude --resume <id>`) — the previously-dead id branch.
    func testBackfilledSessionIdDrivesExplicitClaudeResume() throws {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Claude Code",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "claude",
            arguments: ["--dangerously-skip-permissions"],
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        // The run as `markStarted` builds it: live, pid known, NO native id yet.
        var run = ProcessRun(entryId: entry.id, pid: 4242, status: .running)
        let records: [AgentSessionRecord] = [
            AgentSessionRecord(harness: .claudeCode, sessionId: "pid-4242", cwd: "", running: true),
            AgentSessionRecord(harness: .claudeCode, sessionId: "sess-abc", cwd: "/repo", running: false),
        ]

        // The scanner-observed id is back-filled onto the run...
        let backfills = SessionIdBackfill.sessionIdBackfills(
            runs: [run], entries: [entry], records: records
        )
        XCTAssertEqual(backfills[run.id], "sess-abc")
        run.terminalSessionId = backfills[run.id]
        run.status = .needsRecovery

        // ...and the planner now renders the explicit-id resume, not --continue.
        let plan = try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: run, action: .autoResume)
        XCTAssertEqual(plan.executable, "claude")
        XCTAssertEqual(plan.arguments, ["--dangerously-skip-permissions", "--resume", "sess-abc"])
    }

    /// (b) No record matches the run → `SessionIdBackfill` leaves the id nil → the
    /// planner falls back to `claude --continue` (today's honest behavior).
    func testNoBackfillFallsBackToClaudeContinue() throws {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Claude Code",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "claude",
            arguments: ["--dangerously-skip-permissions"],
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        var run = ProcessRun(entryId: entry.id, pid: 4242, status: .running)
        // Live process observed but no recent record carries a native id.
        let records: [AgentSessionRecord] = [
            AgentSessionRecord(harness: .claudeCode, sessionId: "pid-4242", cwd: "", running: true),
        ]

        let backfills = SessionIdBackfill.sessionIdBackfills(
            runs: [run], entries: [entry], records: records
        )
        XCTAssertNil(backfills[run.id])
        run.terminalSessionId = backfills[run.id]
        run.status = .needsRecovery

        let plan = try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: run, action: .autoResume)
        XCTAssertEqual(plan.arguments, ["--dangerously-skip-permissions", "--continue"])
    }

    /// (b, codex) The codex no-id fallback renders `codex resume --last`.
    func testNoBackfillFallsBackToCodexResumeLast() throws {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            arguments: ["--yolo"],
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        var run = ProcessRun(entryId: entry.id, pid: 7000, status: .running)
        let records: [AgentSessionRecord] = [
            AgentSessionRecord(harness: .openAICodex, sessionId: "pid-7000", cwd: "", running: true),
        ]

        let backfills = SessionIdBackfill.sessionIdBackfills(
            runs: [run], entries: [entry], records: records
        )
        XCTAssertNil(backfills[run.id])
        run.terminalSessionId = backfills[run.id]
        run.status = .needsRecovery

        let plan = try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: run, action: .autoResume)
        XCTAssertEqual(plan.arguments, ["--yolo", "resume", "--last"])
    }

    /// (c) Two same-cwd live sessions → `SessionIdBackfill` leaves BOTH nil → each
    /// planner plan is the honest `--continue` fallback and the two distinct runs
    /// never collapse onto one native id.
    func testTwoSameCwdRunsBothFallBackWithoutSharingAnId() throws {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        func entry() -> ProcessEntry {
            ProcessEntry(
                projectId: project.id,
                name: "Claude Code",
                kind: .terminalAgent,
                agentKind: .claudeCode,
                executable: "claude",
                arguments: ["--dangerously-skip-permissions"],
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: true
            )
        }
        let entryA = entry()
        let entryB = entry()
        let runA = ProcessRun(entryId: entryA.id, pid: 100, status: .running)
        let runB = ProcessRun(entryId: entryB.id, pid: 200, status: .running)
        let records: [AgentSessionRecord] = [
            AgentSessionRecord(harness: .claudeCode, sessionId: "pid-100", cwd: "", running: true),
            AgentSessionRecord(harness: .claudeCode, sessionId: "pid-200", cwd: "", running: true),
            AgentSessionRecord(harness: .claudeCode, sessionId: "sess-A", cwd: "/repo", running: false),
            AgentSessionRecord(harness: .claudeCode, sessionId: "sess-B", cwd: "/repo", running: false),
        ]

        let backfills = SessionIdBackfill.sessionIdBackfills(
            runs: [runA, runB], entries: [entryA, entryB], records: records
        )
        XCTAssertTrue(backfills.isEmpty, "ambiguous same-cwd pair must not share or guess an id")

        for (entry, run) in [(entryA, runA), (entryB, runB)] {
            var recovering = run
            recovering.terminalSessionId = backfills[run.id]
            recovering.status = .needsRecovery
            let plan = try WorkbenchCommandPlanner()
                .recoveryPlan(for: entry, latestRun: recovering, action: .autoResume)
            XCTAssertEqual(plan.arguments, ["--dangerously-skip-permissions", "--continue"])
        }
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
            ouro-wb-exact\t(Detached)
            12345.ouro-wb-abc123\t(Detached)
            malformed-without-dot (Detached)
        1 Socket in /var/folders/example.
        """

        XCTAssertTrue(PersistentTerminalSession.listOutput(output, contains: "ouro-wb-exact"))
        XCTAssertTrue(PersistentTerminalSession.listOutput(output, contains: "ouro-wb-abc123"))
        XCTAssertFalse(PersistentTerminalSession.listOutput(output, contains: "ouro-wb-missing"))
        XCTAssertFalse(PersistentTerminalSession.listOutput(output, contains: "ouro-wb-abc12"))
        XCTAssertFalse(PersistentTerminalSession.listOutput("   \n", contains: "ouro-wb-exact"))
    }

    func testDisplayCommandQuotesEmptyAndShellSensitiveArguments() {
        let plan = TerminalCommandPlan(
            entryId: UUID(),
            executable: "",
            arguments: ["two words", "it's", "$HOME"],
            workingDirectory: "/Users/example/project",
            reason: "quote"
        )

        XCTAssertEqual(plan.displayCommand, "'' 'two words' 'it'\\''s' '$HOME'")
    }

    func testLiveSessionNamesIncludesAttachedDetachedAndExcludesDead() {
        let output = """
        There are screens on:
        \t12345.ouro-wb-aaa\t(Detached)
        \t12346.ouro-wb-bbb\t(Attached)
        \t12347.ouro-wb-ccc\t(Dead ???)
        \t12348.some-other-screen\t(Detached)
        4 Sockets in /var/folders/example.
        """

        let live = PersistentTerminalSession.liveSessionNames(fromListOutput: output)

        XCTAssertEqual(live, ["ouro-wb-aaa", "ouro-wb-bbb"])
        XCTAssertFalse(live.contains("ouro-wb-ccc"), "dead sessions must be excluded")
        XCTAssertFalse(live.contains("some-other-screen"), "non-Workbench sessions ignored")
    }

    func testLiveSessionNamesEmptyWhenNoScreens() {
        XCTAssertEqual(
            PersistentTerminalSession.liveSessionNames(fromListOutput: "No Sockets found in /var/folders/example.\n"),
            []
        )
    }

    func testReattachRecoveryPlanIsAPlainReconnectLaunch() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Claude",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "claude",
            workingDirectory: "/repo",
            trust: .untrusted
        )
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery)
        let plan = try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: run, action: .reattach)

        XCTAssertEqual(plan.recoveryAction, .reattach)
        XCTAssertEqual(plan.reason, "reconnect to running Claude")
        // No checkpoint prompt appended — screen reattaches and ignores the command.
        XCTAssertEqual(plan.arguments, entry.arguments)
        XCTAssertEqual(plan.persistentSessionName, PersistentTerminalSession.sessionName(for: entry.id))
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

    func testNativeResumeWithCustomAgentKindFailsAsUnknownPreset() {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Custom",
            kind: .terminalAgent,
            agentKind: .custom,
            executable: "custom-agent",
            workingDirectory: "/Users/example/project",
            trust: .trusted,
            autoResume: true
        )

        XCTAssertThrowsError(try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: nil, action: .autoResume)) { error in
            XCTAssertEqual(error as? CommandPlanningError, .unknownTerminalAgentPreset(.custom))
        }
    }

    func testNativeResumeWithoutFallbackThrowsWhenSessionIdMissing() {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "GitHub Copilot CLI",
            kind: .terminalAgent,
            agentKind: .githubCopilotCLI,
            executable: "gh",
            arguments: ["copilot"],
            workingDirectory: "/Users/example/project",
            trust: .trusted,
            autoResume: true
        )

        XCTAssertThrowsError(try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: nil, action: .autoResume)) { error in
            XCTAssertEqual(error as? CommandPlanningError, .missingSessionId(entryName: "GitHub Copilot CLI"))
        }
    }

    func testNativeResumeForCheckpointPresetWithSessionIdFallsBackToEntryExecutable() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "GitHub Copilot CLI",
            kind: .terminalAgent,
            agentKind: .githubCopilotCLI,
            executable: "gh",
            arguments: ["copilot", "--", "--yolo"],
            workingDirectory: "/Users/example/project",
            trust: .trusted,
            autoResume: true
        )
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery, terminalSessionId: "ignored")

        let plan = try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: run, action: .autoResume)

        XCTAssertEqual(plan.executable, "gh")
        XCTAssertEqual(plan.arguments, ["copilot", "--", "--yolo"])
        XCTAssertEqual(plan.reason, "resume GitHub Copilot CLI using native session metadata")
    }

    func testAutoResumeForUndetectedAgentFallsBackToLaunchPlan() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Unknown TUI",
            kind: .terminalAgent,
            executable: "aider",
            arguments: ["--yes"],
            workingDirectory: "/Users/example/project",
            trust: .trusted,
            autoResume: true
        )

        let plan = try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: nil, action: .autoResume)

        XCTAssertEqual(plan.executable, "aider")
        XCTAssertEqual(plan.arguments, ["--yes"])
        XCTAssertEqual(plan.recoveryAction, .autoResume)
    }

    func testRespawnForCustomAgentKindUsesCheckpointPrompt() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Custom Agent",
            kind: .terminalAgent,
            agentKind: .custom,
            executable: "custom-agent",
            workingDirectory: "/Users/example/project",
            trust: .trusted,
            autoResume: true
        )

        let plan = try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: nil, action: .respawn)

        XCTAssertEqual(plan.reason, "respawn Custom Agent with checkpoint recovery prompt")
        // F12a gap 5 — a custom (non-Copilot) agent keeps the positional path.
        XCTAssertEqual(plan.checkpointPromptDelivery, .positional)
        XCTAssertTrue(plan.arguments.last?.contains("Recover this Ouro Workbench terminal-agent session") == true)
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
        // F12a gap 5 — Copilot's TUI ignores anything after `--`, so the checkpoint
        // prompt must NOT be appended as a positional. The argv is exactly the
        // launch flags; the prompt rides checkpointPromptDelivery == .sendAfterLaunch
        // to be typed once the TUI is interactive.
        XCTAssertEqual(plan.arguments, ["copilot", "--", "--yolo"])
        XCTAssertEqual(plan.recoveryAction, .respawn)
        XCTAssertEqual(plan.reason, "respawn GitHub Copilot CLI with checkpoint recovery prompt")
        guard case let .sendAfterLaunch(text) = plan.checkpointPromptDelivery else {
            return XCTFail("Copilot respawn must deliver the prompt via sendAfterLaunch, not a positional argv token")
        }
        XCTAssertTrue(text.contains("Recover this Ouro Workbench terminal-agent session"))
        XCTAssertTrue(text.contains("/tmp/transcript.log"))
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
        // F12a gap 5 — a shell-wrapped Copilot is still detected as Copilot, so the
        // prompt rides sendAfterLaunch (not the argv, which the TUI would ignore).
        // The shell argv keeps exactly its two tokens; no prompt is appended.
        XCTAssertEqual(plan.arguments, ["-lc", "gh copilot -- --yolo"])
        guard case let .sendAfterLaunch(text) = plan.checkpointPromptDelivery else {
            return XCTFail("shell-wrapped Copilot respawn must deliver the prompt via sendAfterLaunch")
        }
        XCTAssertTrue(text.contains("Recover this Ouro Workbench terminal-agent session"))
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
        // F12a gap 5 — a generic argv-reading TUI keeps the positional path (many
        // custom agents DO read an argv prompt), so the prompt stays the last argv
        // token AND checkpointPromptDelivery is .positional (nothing typed later).
        XCTAssertEqual(plan.checkpointPromptDelivery, .positional)
        XCTAssertTrue(plan.arguments.last?.contains("Recover this Ouro Workbench terminal-agent session") == true)
        XCTAssertTrue(plan.arguments.last?.contains("/tmp/generic-transcript.log") == true)
    }

    func testCheckpointRespawnWithoutTranscriptUsesReconstructionGuidance() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Generic TUI",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            arguments: ["-lc", "aider --yes"],
            workingDirectory: "/Users/example/project",
            trust: .trusted,
            autoResume: true
        )
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery, transcriptPath: nil)

        let plan = try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: run, action: .respawn)

        XCTAssertTrue(plan.arguments.last?.contains("No previous transcript path is available") == true)
    }

    func testManualAndNoActionRecoveryPlansAreForReview() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Shell",
            kind: .shell,
            executable: "/bin/zsh",
            workingDirectory: "/Users/example/project",
            trust: .trusted
        )

        for action in [RecoveryAction.manualActionNeeded, .noAction] {
            let plan = try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: nil, action: action)
            XCTAssertEqual(plan.recoveryAction, action)
            XCTAssertEqual(plan.reason, "prepare Shell command for manual review")
            XCTAssertEqual(plan.kind, .manualReview)
        }
    }

    // U40: every plan the planner produces carries a typed `kind` so the
    // post-launch status line can read a plain operator sentence instead of the
    // technical `reason`. The raw `reason` stays untouched (asserted above) for
    // logs / disclosure.

    func testLaunchPlanIsKindLaunch() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            arguments: ["--yolo"],
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        let plan = try WorkbenchCommandPlanner().launchPlan(for: entry)
        XCTAssertEqual(plan.kind, .launch)
        XCTAssertEqual(plan.reason, "launch configured Codex session")
    }

    func testReattachRecoveryPlanIsKindReattach() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Claude",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "claude",
            workingDirectory: "/repo",
            trust: .trusted
        )
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery)
        let plan = try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: run, action: .reattach)
        XCTAssertEqual(plan.kind, .reattach)
    }

    func testRespawnRecoveryPlanIsKindRespawn() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Generic TUI",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            arguments: ["-lc", "aider --yes"],
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery)
        let plan = try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: run, action: .respawn)
        XCTAssertEqual(plan.kind, .respawn)
    }

    func testAutoResumeRecoveryPlanIsKindResume() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Claude",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "claude",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery, terminalSessionId: "sess-1")
        let plan = try WorkbenchCommandPlanner().recoveryPlan(for: entry, latestRun: run, action: .autoResume)
        XCTAssertEqual(plan.kind, .resume)
    }
}
