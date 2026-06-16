import XCTest
@testable import OuroWorkbenchCore

final class WorkspaceSummaryTests: XCTestCase {
    func testSummarySurfacesHumanWaitsFirst() {
        let project = WorkbenchProject(name: "Project", rootPath: "/tmp/project")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            workingDirectory: "/tmp/project",
            trust: .trusted,
            autoResume: true,
            attention: .waitingOnHuman,
            lastSummary: "Codex wants a product decision"
        )
        let state = WorkspaceState(
            projects: [project],
            processEntries: [entry],
            processRuns: [ProcessRun(entryId: entry.id, status: .waitingForInput)]
        )

        let summary = WorkspaceSummarizer().summarize(state)

        XCTAssertEqual(summary.waitingOnHuman.map(\.name), ["Codex"])
        XCTAssertEqual(summary.oneLineStatus, "Codex waiting on human input")
    }

    func testBossPromptIncludesProcessAndRecoveryTruth() {
        let project = WorkbenchProject(name: "Project", rootPath: "/tmp/project")
        let archiveProject = WorkbenchProject(name: "Backlog", rootPath: "/tmp/backlog")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "GitHub Copilot CLI",
            kind: .terminalAgent,
            agentKind: .githubCopilotCLI,
            executable: "copilot",
            workingDirectory: "/tmp/project",
            trust: .trusted,
            autoResume: true,
            notes: "Keep this lane on PR review follow-through.\nUse yolo mode."
        )
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery, transcriptPath: "/tmp/copilot.log")
        let actionLogEntry = WorkbenchActionLogEntry(
            occurredAt: Date(timeIntervalSince1970: 1_779_552_000),
            source: "external:smoke",
            action: "recover",
            targetEntryId: entry.id,
            targetName: entry.name,
            result: "Skipped recover for GitHub Copilot CLI: latest run status is running",
            succeeded: false
        )
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "slugger"),
            bossWatchEnabled: true,
            bossPaneCollapsed: true,
            selectedProjectId: project.id,
            projects: [project],
            processEntries: [entry],
            processRuns: [run],
            actionLog: [actionLogEntry]
        )
        var organizedState = state
        organizedState.projects.append(archiveProject)
        let summary = WorkspaceSummarizer().summarize(state)

        let prompt = BossAgentPromptBuilder().checkInPrompt(
            question: "is anything waiting on me?",
            state: organizedState,
            summary: summary,
            executableHealth: [
                entry.id: ExecutableHealth(
                    executable: "copilot",
                    resolvedPath: "/opt/homebrew/bin/copilot",
                    status: .available,
                    detail: "Found /opt/homebrew/bin/copilot."
                )
            ],
            gitStatus: [
                entry.id: GitSessionStatus(
                    isRepo: true,
                    branch: "feature/x",
                    dirty: true,
                    ahead: 2,
                    behind: 1
                )
            ],
            ouroAgents: [
                OuroAgentRecord(
                    name: "slugger",
                    bundlePath: "/Users/ari/AgentBundles/slugger.ouro",
                    configPath: "/Users/ari/AgentBundles/slugger.ouro/agent.json",
                    status: .ready,
                    detail: "ready",
                    humanFacing: OuroAgentLane(provider: "minimax", model: "MiniMax-M2.7"),
                    agentFacing: OuroAgentLane(provider: "minimax", model: "MiniMax-M2.5")
                )
            ]
        )

        XCTAssertTrue(prompt.contains("Boss agent: slugger"))
        XCTAssertTrue(prompt.contains("Question: is anything waiting on me?"))
        XCTAssertTrue(prompt.contains("Boss Watch: enabled"))
        XCTAssertTrue(prompt.contains("Boss Pane: collapsed"))
        XCTAssertTrue(prompt.contains("Selected group: Project"))
        XCTAssertTrue(prompt.contains("Local Ouro agents:"))
        XCTAssertTrue(prompt.contains("slugger: selected_boss=true, status=ready"))
        XCTAssertTrue(prompt.contains("human minimax/MiniMax-M2.7"))
        XCTAssertTrue(prompt.contains("Organization:"))
        XCTAssertTrue(prompt.contains("* Project (id=\(project.id.uuidString), root=/tmp/project): GitHub Copilot CLI"))
        XCTAssertTrue(prompt.contains("- Backlog (id=\(archiveProject.id.uuidString), root=/tmp/backlog): no active terminals"))
        XCTAssertTrue(prompt.contains("GitHub Copilot CLI"))
        XCTAssertTrue(prompt.contains("group=Project, cli=GitHub Copilot CLI"))
        XCTAssertTrue(prompt.contains("trust=trusted"))
        XCTAssertTrue(prompt.contains("executable_health=available"))
        XCTAssertTrue(prompt.contains("executable_path=/opt/homebrew/bin/copilot"))
        XCTAssertTrue(prompt.contains("git=feature/x (dirty, +2/-1)"))
        XCTAssertTrue(prompt.contains("transcript=/tmp/copilot.log"))
        XCTAssertTrue(prompt.contains("notes=Keep this lane on PR review follow-through. Use yolo mode."))
        XCTAssertTrue(prompt.contains("action=respawn"))
        XCTAssertTrue(prompt.contains("```ouro-workbench-actions"))
        XCTAssertTrue(prompt.contains("\"action\":\"recover\""))
        XCTAssertTrue(prompt.contains("Recent action log:"))
        XCTAssertTrue(prompt.contains("source=external:smoke"))
        XCTAssertTrue(prompt.contains("result=Skipped recover for GitHub Copilot CLI"))
    }

    func testChangeSummarizerCapturesRunStatusAttentionArchiveAndActions() {
        let project = WorkbenchProject(name: "Project", rootPath: "/tmp/project")
        var previousEntry = ProcessEntry(
            projectId: project.id,
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            workingDirectory: "/tmp/project",
            trust: .trusted,
            autoResume: true,
            attention: .active
        )
        let run = ProcessRun(
            entryId: previousEntry.id,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        let previous = WorkspaceState(
            projects: [project],
            processEntries: [previousEntry],
            processRuns: [run]
        )
        previousEntry.attention = .waitingOnHuman
        previousEntry.isArchived = true
        let exitedRun = ProcessRun(
            id: run.id,
            entryId: previousEntry.id,
            status: .exited,
            startedAt: run.startedAt
        )
        let action = WorkbenchActionLogEntry(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            occurredAt: Date(timeIntervalSince1970: 2_000),
            source: "boss:slugger",
            action: "sendInput",
            targetEntryId: previousEntry.id,
            targetName: previousEntry.name,
            result: "Sent input to Codex",
            succeeded: true
        )
        let current = WorkspaceState(
            projects: [project],
            processEntries: [previousEntry],
            processRuns: [exitedRun],
            actionLog: [action]
        )

        let changes = WorkspaceChangeSummarizer().summarize(
            previous: previous,
            current: current,
            occurredAt: Date(timeIntervalSince1970: 3_000)
        )

        XCTAssertTrue(changes.contains { $0.title == "Session archived" && $0.detail.contains("Codex") })
        XCTAssertTrue(changes.contains { $0.title == "Attention changed" && $0.detail.contains("waitingOnHuman") })
        XCTAssertTrue(changes.contains { $0.title == "Run status changed" && $0.detail.contains("running to exited") })
        XCTAssertTrue(changes.contains { $0.title == "Action applied" && $0.detail.contains("Sent input to Codex") })
    }

    func testChangeSummarizerReplacesLatestRunAndIgnoresExistingActions() {
        let project = WorkbenchProject(name: "Project", rootPath: "/Users/example/project")
        let entry = ProcessEntry(projectId: project.id, name: "Agent", kind: .terminalAgent, agentKind: .custom, executable: "ouro", arguments: ["run"], workingDirectory: project.rootPath)
        let older = ProcessRun(entryId: entry.id, status: .exited, startedAt: Date(timeIntervalSince1970: 1), exitCode: 1)
        let newer = ProcessRun(entryId: entry.id, pid: 42, status: .running, startedAt: Date(timeIntervalSince1970: 2))
        let existingAction = WorkbenchActionLogEntry(occurredAt: Date(timeIntervalSince1970: 3), source: "boss:slugger", action: "note", targetEntryId: entry.id, targetName: entry.name, result: "old", succeeded: true)
        let newAction = WorkbenchActionLogEntry(occurredAt: Date(timeIntervalSince1970: 4), source: "boss:slugger", action: "note", targetEntryId: entry.id, targetName: entry.name, result: "new", succeeded: true)
        let previous = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [older], actionLog: [existingAction])
        let current = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [older, newer], actionLog: [existingAction, newAction])

        let changes = WorkspaceChangeSummarizer().summarize(previous: previous, current: current, occurredAt: Date(timeIntervalSince1970: 5))

        XCTAssertTrue(changes.contains { $0.title.contains("Run") && $0.detail.contains(newer.id.uuidString) })
        XCTAssertFalse(changes.contains { $0.detail.contains("old") })
        XCTAssertTrue(changes.contains { $0.title == "Action applied" && $0.detail.contains("new") })
    }

    func testChangeSummarizerCapturesAddedRenamedRestoredRemovedSkippedAndRunStarted() {
        let project = WorkbenchProject(name: "Project", rootPath: "/Users/example/project")
        let removed = ProcessEntry(projectId: project.id, name: "Removed", kind: .shell, executable: "/bin/zsh", workingDirectory: project.rootPath)
        var renamed = ProcessEntry(projectId: project.id, name: "Old Name", kind: .shell, executable: "/bin/zsh", workingDirectory: project.rootPath, isArchived: true)
        let previous = WorkspaceState(projects: [project], processEntries: [removed, renamed])
        renamed.name = "New Name"
        renamed.isArchived = false
        let added = ProcessEntry(projectId: project.id, name: "Added", kind: .shell, executable: "/bin/zsh", workingDirectory: project.rootPath)
        let run = ProcessRun(entryId: renamed.id, status: .running, startedAt: Date(timeIntervalSince1970: 10))
        let skipped = WorkbenchActionLogEntry(
            occurredAt: Date(timeIntervalSince1970: 20),
            source: "boss:slugger",
            action: "recover",
            targetEntryId: renamed.id,
            targetName: renamed.name,
            result: "Already running",
            succeeded: false
        )
        let current = WorkspaceState(projects: [project], processEntries: [renamed, added], processRuns: [run], actionLog: [skipped])

        let changes = WorkspaceChangeSummarizer().summarize(previous: previous, current: current, occurredAt: Date(timeIntervalSince1970: 30))

        XCTAssertTrue(changes.contains { $0.title == "Session added" && $0.detail == "Added was added to the workbench" })
        XCTAssertTrue(changes.contains { $0.title == "Session renamed" && $0.detail == "Old Name is now New Name" })
        XCTAssertTrue(changes.contains { $0.title == "Session restored" && $0.detail == "New Name is active" })
        XCTAssertTrue(changes.contains { $0.title == "Session removed" && $0.detail == "Removed was removed from the workbench" })
        XCTAssertTrue(changes.contains { $0.title == "Run started" && $0.detail.contains(run.id.uuidString) })
        XCTAssertTrue(changes.contains { $0.title == "Action skipped" && $0.detail.contains("Already running") })
    }

    func testLatestRunSelectionAndDefaultSummariesCoverExitedAndConfigured() {
        let project = WorkbenchProject(name: "Project", rootPath: "/Users/example/project")
        let exited = ProcessEntry(projectId: project.id, name: "Exited", kind: .shell, executable: "/bin/zsh", workingDirectory: project.rootPath)
        let configured = ProcessEntry(projectId: project.id, name: "Configured", kind: .shell, executable: "/bin/zsh", workingDirectory: project.rootPath)
        let exitedWithCode = ProcessEntry(projectId: project.id, name: "Exited Code", kind: .shell, executable: "/bin/zsh", workingDirectory: project.rootPath)
        let older = ProcessRun(entryId: exited.id, status: .running, startedAt: Date(timeIntervalSince1970: 1))
        let newer = ProcessRun(entryId: exited.id, status: .exited, startedAt: Date(timeIntervalSince1970: 2), exitCode: nil)
        let codeRun = ProcessRun(entryId: exitedWithCode.id, status: .exited, startedAt: Date(timeIntervalSince1970: 3), exitCode: 7)
        let state = WorkspaceState(projects: [project], processEntries: [exited, configured, exitedWithCode], processRuns: [older, newer, codeRun])

        let summary = WorkspaceSummarizer().summarize(state)

        XCTAssertTrue(summary.processSnapshots.contains { $0.name == "Exited" && $0.summary == "Exited exited with code unknown" && $0.latestRunId == newer.id })
        XCTAssertTrue(summary.processSnapshots.contains { $0.name == "Exited Code" && $0.summary == "Exited Code exited with code 7" })
        XCTAssertTrue(summary.processSnapshots.contains { $0.name == "Configured" && $0.summary == "Configured is configured" })
        XCTAssertEqual(summary.oneLineStatus, "0 running, 0 recovery actions")
    }

    func testConfiguredLatestRunUsesConfiguredSummary() {
        let project = WorkbenchProject(name: "Project", rootPath: "/Users/example/project")
        let configured = ProcessEntry(projectId: project.id, name: "Configured Run", kind: .shell, executable: "/bin/zsh", workingDirectory: project.rootPath)
        let run = ProcessRun(entryId: configured.id, status: .configured, startedAt: Date(timeIntervalSince1970: 1))
        let state = WorkspaceState(projects: [project], processEntries: [configured], processRuns: [run])

        let summary = WorkspaceSummarizer().summarize(state)

        XCTAssertEqual(summary.processSnapshots.first?.summary, "Configured Run is configured")
    }

    func testBossPromptIncludesRecentWorkspaceChanges() {
        let project = WorkbenchProject(name: "Project", rootPath: "/tmp/project")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            workingDirectory: "/tmp/project",
            trust: .trusted
        )
        let state = WorkspaceState(projects: [project], processEntries: [entry])
        let summary = WorkspaceSummarizer().summarize(state)

        let prompt = BossAgentPromptBuilder().checkInPrompt(
            question: "watch",
            state: state,
            summary: summary,
            recentChanges: [
                WorkspaceChangeSummary(
                    occurredAt: Date(timeIntervalSince1970: 1_779_552_000),
                    entryId: entry.id,
                    title: "Attention changed",
                    detail: "Codex attention changed from active to waitingOnHuman"
                )
            ]
        )

        XCTAssertTrue(prompt.contains("Recent workspace changes:"))
        XCTAssertTrue(prompt.contains("Attention changed - Codex attention changed"))
    }
}
