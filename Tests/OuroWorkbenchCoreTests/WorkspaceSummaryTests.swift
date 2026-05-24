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
            autoResume: true
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
            summary: summary
        )

        XCTAssertTrue(prompt.contains("Boss agent: slugger"))
        XCTAssertTrue(prompt.contains("Question: is anything waiting on me?"))
        XCTAssertTrue(prompt.contains("GitHub Copilot CLI"))
        XCTAssertTrue(prompt.contains("trust=trusted"))
        XCTAssertTrue(prompt.contains("transcript=/tmp/copilot.log"))
        XCTAssertTrue(prompt.contains("action=respawn"))
        XCTAssertTrue(prompt.contains("```ouro-workbench-actions"))
        XCTAssertTrue(prompt.contains("\"action\":\"recover\""))
        XCTAssertTrue(prompt.contains("Recent action log:"))
        XCTAssertTrue(prompt.contains("source=external:smoke"))
        XCTAssertTrue(prompt.contains("result=Skipped recover for GitHub Copilot CLI"))
    }
}
