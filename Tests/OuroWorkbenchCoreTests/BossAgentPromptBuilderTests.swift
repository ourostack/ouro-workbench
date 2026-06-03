import XCTest
@testable import OuroWorkbenchCore

final class BossAgentPromptBuilderTests: XCTestCase {
    /// Builds a small workspace where one trusted session is waiting on a
    /// human, so `oneLineStatus` is deterministic.
    private func makeFixture() -> (state: WorkspaceState, summary: WorkspaceSummary) {
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
        return (state, summary)
    }

    func testCheckInTriggerCarriesProtocolAndPulse() {
        let (_, summary) = makeFixture()
        let question = "is anything waiting on me?"

        let trigger = BossAgentPromptBuilder().checkInTrigger(question: question, summary: summary)

        // Tool-grounding: points the boss at its Workbench MCP tools.
        XCTAssertTrue(trigger.contains("workbench_status"))
        // Carries the question verbatim.
        XCTAssertTrue(trigger.contains(question))
        // Keeps the auditable decision protocol.
        XCTAssertTrue(trigger.contains("ouro-workbench-decisions"))
        // Keeps a one-line pulse so a tool-skipping boss still reports/escalates.
        XCTAssertEqual(summary.oneLineStatus, "Codex waiting on human input")
        XCTAssertTrue(trigger.contains(summary.oneLineStatus))
    }

    func testCheckInTriggerIsSubstantiallyShorterThanFullPrompt() {
        let (state, summary) = makeFixture()
        let question = "is anything waiting on me?"
        let builder = BossAgentPromptBuilder()

        let trigger = builder.checkInTrigger(question: question, summary: summary)
        let fullPrompt = builder.checkInPrompt(
            question: question,
            state: state,
            summary: summary
        )

        // The thin trigger drops the per-session state dump, so it must be
        // materially shorter than the full embed for the same inputs.
        XCTAssertLessThan(trigger.count, fullPrompt.count)
    }
}
