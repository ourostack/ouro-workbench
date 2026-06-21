import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchSessionsRendererTests: XCTestCase {
    private let renderer = WorkbenchSessionsRenderer()

    /// human-owned running session, agent-owned (slugger) session whose latest
    /// run exited cleanly, and an archived session with no runs.
    private func makeFixture() -> (state: WorkspaceState, human: ProcessEntry, agent: ProcessEntry, archived: ProcessEntry) {
        let project = WorkbenchProject(name: "Proj", rootPath: "/tmp/proj")
        let human = ProcessEntry(
            projectId: project.id,
            name: "My Shell",
            kind: .shell,
            executable: "/bin/zsh",
            workingDirectory: "/tmp/proj",
            trust: .trusted,
            attention: .active,
            owner: .human
        )
        let agent = ProcessEntry(
            projectId: project.id,
            name: "claude-fix-bug",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "claude",
            workingDirectory: "/tmp/proj",
            trust: .untrusted,
            attention: .waitingOnHuman,
            attentionReason: "Do you want to make this edit?",
            owner: .agent(name: "slugger")
        )
        let archived = ProcessEntry(
            projectId: project.id,
            name: "old-terminal",
            kind: .shell,
            executable: "/bin/zsh",
            workingDirectory: "/tmp/proj",
            isArchived: true,
            owner: .human
        )
        let state = WorkspaceState(
            projects: [project],
            processEntries: [human, agent, archived],
            processRuns: [
                ProcessRun(entryId: human.id, pid: 123, status: .running, startedAt: Date(timeIntervalSince1970: 5_000)),
                // Two runs for the agent — the renderer must pick the newer.
                ProcessRun(entryId: agent.id, pid: 555, status: .running, startedAt: Date(timeIntervalSince1970: 1_000)),
                ProcessRun(entryId: agent.id, status: .exited, startedAt: Date(timeIntervalSince1970: 2_000), exitCode: 0)
            ]
        )
        return (state, human, agent, archived)
    }

    func testExcludesArchivedByDefaultAndMapsCoreFields() throws {
        let f = makeFixture()
        let snapshots = renderer.snapshots(state: f.state)

        XCTAssertEqual(snapshots.count, 2, "archived session is excluded by default")

        let human = try XCTUnwrap(snapshots.first { $0.id == f.human.id.uuidString })
        XCTAssertEqual(human.owner.kind, "human")
        XCTAssertNil(human.owner.name)
        XCTAssertEqual(human.status, "running")
        XCTAssertEqual(human.pid, 123)
        XCTAssertNil(human.exitCode)
        XCTAssertEqual(human.attention, "active")
        XCTAssertEqual(human.needsHuman, false)
        XCTAssertEqual(human.group, "Proj")
        XCTAssertEqual(human.trust, "trusted")
    }

    func testPicksLatestRunAndMapsAgentOwner() throws {
        let f = makeFixture()
        let snapshots = renderer.snapshots(state: f.state)
        let agent = try XCTUnwrap(snapshots.first { $0.id == f.agent.id.uuidString })

        // Newer run (t=2000, exited) wins over the older running run (t=1000).
        XCTAssertEqual(agent.status, "exited")
        XCTAssertEqual(agent.exitCode, 0)
        XCTAssertNil(agent.pid, "latest run has no pid")
        XCTAssertEqual(agent.owner.kind, "agent")
        XCTAssertEqual(agent.owner.name, "slugger")
        XCTAssertEqual(agent.attention, "waitingOnHuman")
        // #U25b: the raw attention is preserved, but this is an AGENT-owned session
        // parked at its own loop's prompt — the agent's turn, not the human's — so
        // needsHuman is false (it used to falsely read true). See the dedicated
        // driver/actionable tests below.
        XCTAssertEqual(agent.needsHuman, false)
        XCTAssertEqual(agent.driver, "agent")
        XCTAssertFalse(agent.actionable)
        XCTAssertEqual(agent.trust, "untrusted")
        // U10: the operator-facing reason is exposed to the boss over MCP, not
        // only rendered in the UI, so the boss's "this one is waiting because X"
        // can be audited against the live view.
        XCTAssertEqual(agent.attentionReason, "Do you want to make this edit?")
    }

    func testSnapshotOmitsAttentionReasonWhenNone() throws {
        let f = makeFixture()
        let human = try XCTUnwrap(renderer.snapshots(state: f.state).first { $0.id == f.human.id.uuidString })
        XCTAssertNil(human.attentionReason, "an active session with no derived reason carries none")
    }

    func testOwnerFilterReturnsOnlyThatAgentsSessions() {
        let f = makeFixture()
        let mine = renderer.snapshots(state: f.state, owner: "slugger")
        XCTAssertEqual(mine.map(\.id), [f.agent.id.uuidString])

        XCTAssertTrue(renderer.snapshots(state: f.state, owner: "nobody").isEmpty)
    }

    func testNameFilterIsCaseInsensitive() {
        let f = makeFixture()
        let hits = renderer.snapshots(state: f.state, name: "CLAUDE-FIX-BUG")
        XCTAssertEqual(hits.map(\.id), [f.agent.id.uuidString])
    }

    func testIncludeArchivedReturnsAll() {
        let f = makeFixture()
        let all = renderer.snapshots(state: f.state, includeArchived: true)
        XCTAssertEqual(all.count, 3)
        let archived = all.first { $0.id == f.archived.id.uuidString }
        // No runs → status falls back to configured.
        XCTAssertEqual(archived?.status, "configured")
        XCTAssertEqual(archived?.isArchived, true)
    }

    func testAgentOwnedWaitingRowIsAgentDrivenAndNotHumanActionable() throws {
        // #U25b: the agent fixture is waitingOnHuman + agent-owned. Its row must
        // carry driver=agent / actionable=false and needsHuman=false, so the boss
        // can tell from the row data (not the preamble) that the agent's own loop
        // is driving it — not a human-attention item to act on.
        let f = makeFixture()
        let agent = try XCTUnwrap(renderer.snapshots(state: f.state).first { $0.id == f.agent.id.uuidString })
        XCTAssertEqual(agent.attention, "waitingOnHuman", "raw attention is preserved on the row")
        XCTAssertEqual(agent.driver, "agent")
        XCTAssertFalse(agent.actionable)
        XCTAssertFalse(agent.needsHuman, "an agent-driven prompt is not a human-attention item")
    }

    func testHumanOwnedWaitingRowIsHumanDrivenAndActionable() throws {
        let project = WorkbenchProject(name: "Proj", rootPath: "/tmp/proj")
        let humanWaiting = ProcessEntry(
            projectId: project.id,
            name: "human-asker",
            kind: .terminalAgent,
            executable: "claude",
            workingDirectory: "/tmp/proj",
            attention: .waitingOnHuman,
            owner: .human
        )
        let state = WorkspaceState(projects: [project], processEntries: [humanWaiting], processRuns: [])
        let row = try XCTUnwrap(renderer.snapshots(state: state).first)
        XCTAssertEqual(row.driver, "human")
        XCTAssertTrue(row.actionable)
        XCTAssertTrue(row.needsHuman)
    }

    func testAgentOwnedNeedsBossReviewRowStaysHumanActionable() throws {
        // A genuine boss-raised review item on an agent-owned session is still a
        // human-attention item — suppression of the agent's own loop must not hide
        // a real review.
        let project = WorkbenchProject(name: "Proj", rootPath: "/tmp/proj")
        let agentReview = ProcessEntry(
            projectId: project.id,
            name: "agent-review",
            kind: .terminalAgent,
            executable: "claude",
            workingDirectory: "/tmp/proj",
            attention: .needsBossReview,
            owner: .agent(name: "slugger")
        )
        let state = WorkspaceState(projects: [project], processEntries: [agentReview], processRuns: [])
        let row = try XCTUnwrap(renderer.snapshots(state: state).first)
        XCTAssertEqual(row.driver, "agent")
        XCTAssertTrue(row.actionable, "a boss-raised review is actionable even on an agent-owned session")
        XCTAssertTrue(row.needsHuman)
    }

    func testAttentionFilterReturnsOnlyMatchingStates() {
        let f = makeFixture()
        // The agent fixture is waitingOnHuman; the human is active.
        let waiting = renderer.snapshots(state: f.state, attention: ["waitingOnHuman", "blocked", "needsBossReview"])
        XCTAssertEqual(waiting.map(\.id), [f.agent.id.uuidString])

        // An attention set matching nothing returns empty (a loop that only cares
        // about the attention queue never receives idle/active rows).
        XCTAssertTrue(renderer.snapshots(state: f.state, attention: ["blocked"]).isEmpty)
    }

    func testPromptSnippetsAttachToTheirRow() throws {
        let f = makeFixture()
        let snapshots = renderer.snapshots(
            state: f.state,
            promptSnippets: [f.agent.id: "Apply this edit? (y/n)"]
        )
        let agent = try XCTUnwrap(snapshots.first { $0.id == f.agent.id.uuidString })
        let human = try XCTUnwrap(snapshots.first { $0.id == f.human.id.uuidString })
        XCTAssertEqual(agent.attentionPrompt, "Apply this edit? (y/n)")
        XCTAssertNil(human.attentionPrompt, "a row with no supplied snippet carries none")
    }

    /// The client treats absent keys as "not applicable", so nil optionals must
    /// be omitted from the encoded JSON (synthesized encodeIfPresent).
    func testEncodedJSONOmitsNilOptionals() throws {
        let f = makeFixture()
        let human = try XCTUnwrap(renderer.snapshots(state: f.state).first { $0.id == f.human.id.uuidString })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = try XCTUnwrap(String(data: try encoder.encode(human), encoding: .utf8))

        XCTAssertTrue(json.contains("\"pid\":123"))
        XCTAssertTrue(json.contains("\"group\":\"Proj\""))
        XCTAssertFalse(json.contains("exitCode"), "nil exitCode is omitted")
        XCTAssertFalse(json.contains("transcriptPath"), "nil transcriptPath is omitted")
        XCTAssertFalse(json.contains("attentionReason"), "nil attentionReason is omitted")
        XCTAssertFalse(json.contains("attentionPrompt"), "nil attentionPrompt is omitted")
    }
}
