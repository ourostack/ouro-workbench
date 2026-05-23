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
        let run = ProcessRun(entryId: entry.id, status: .needsRecovery)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [run])
        let summary = WorkspaceSummarizer().summarize(state)

        let prompt = BossAgentPromptBuilder().checkInPrompt(
            question: "is anything waiting on me?",
            state: state,
            summary: summary
        )

        XCTAssertTrue(prompt.contains("Boss agent: slugger"))
        XCTAssertTrue(prompt.contains("Question: is anything waiting on me?"))
        XCTAssertTrue(prompt.contains("GitHub Copilot CLI"))
        XCTAssertTrue(prompt.contains("action=respawn"))
    }
}
