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

    func testCheckInTriggerWeavesInTheResolvedOwnerName() {
        // The scaffold reports on the ACTUAL operator — the owner name is injected,
        // never the hardcoded "Ari".
        let (_, summary) = makeFixture()
        let trigger = BossAgentPromptBuilder(ownerName: "Dana Lee").checkInTrigger(question: "q", summary: summary)
        XCTAssertTrue(trigger.contains("what is waiting on Dana Lee"))
        XCTAssertFalse(trigger.contains("Ari"))
    }

    func testCheckInPromptSurfacesSessionOwnerAndAgentGuidance() {
        // A workspace with both a human-owned waiting session and an
        // agent-owned (agent-driven) session.
        let project = WorkbenchProject(name: "Project", rootPath: "/tmp/project")
        let humanEntry = ProcessEntry(
            projectId: project.id,
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            workingDirectory: "/tmp/project",
            trust: .trusted,
            attention: .waitingOnHuman,
            lastSummary: "Codex wants a product decision",
            owner: .human
        )
        let agentEntry = ProcessEntry(
            projectId: project.id,
            name: "Slugger coding session",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            workingDirectory: "/tmp/project",
            trust: .trusted,
            attention: .waitingOnHuman,
            lastSummary: "Slugger is iterating on a fix",
            owner: .agent(name: "slugger")
        )
        let state = WorkspaceState(
            projects: [project],
            processEntries: [humanEntry, agentEntry],
            processRuns: [
                ProcessRun(entryId: humanEntry.id, status: .waitingForInput),
                ProcessRun(entryId: agentEntry.id, status: .waitingForInput)
            ]
        )
        let summary = WorkspaceSummarizer().summarize(state)

        // Mirrors how workbenchStatus() invokes the builder.
        let prompt = BossAgentPromptBuilder().checkInPrompt(
            question: "What is currently going on in Ouro Workbench?",
            state: state,
            summary: summary,
            executableHealth: [:],
            gitStatus: [:],
            machineFriend: SessionFriend.machineOwner(),
            waitingPrompts: [:]
        )

        // (a) The per-session listing labels each session's owner.
        XCTAssertTrue(prompt.contains("owner=agent:slugger"))
        XCTAssertTrue(prompt.contains("owner=human"))
        // (b) The decision protocol tells the boss to hold agent-owned sessions.
        XCTAssertTrue(prompt.contains("Sessions owned by an agent (owner=agent:<name>) are driven by that agent's own loop"))
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
