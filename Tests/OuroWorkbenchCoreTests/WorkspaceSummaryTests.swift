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
            projects: [project],
            processEntries: [entry],
            processRuns: [run],
            actionLog: [actionLogEntry]
        )
        let summary = WorkspaceSummarizer().summarize(state)

        let prompt = BossAgentPromptBuilder().checkInPrompt(
            question: "is anything waiting on me?",
            state: state,
            summary: summary,
            executableHealth: [
                entry.id: ExecutableHealth(
                    executable: "copilot",
                    resolvedPath: "/opt/homebrew/bin/copilot",
                    status: .available,
                    detail: "Found /opt/homebrew/bin/copilot."
                )
            ]
        )

        XCTAssertTrue(prompt.contains("Boss agent: slugger"))
        XCTAssertTrue(prompt.contains("Question: is anything waiting on me?"))
        XCTAssertTrue(prompt.contains("GitHub Copilot CLI"))
        XCTAssertTrue(prompt.contains("trust=trusted"))
        XCTAssertTrue(prompt.contains("executable_health=available"))
        XCTAssertTrue(prompt.contains("executable_path=/opt/homebrew/bin/copilot"))
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
