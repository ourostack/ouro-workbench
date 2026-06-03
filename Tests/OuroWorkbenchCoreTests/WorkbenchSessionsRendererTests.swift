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
        XCTAssertEqual(agent.needsHuman, true)
        XCTAssertEqual(agent.trust, "untrusted")
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
    }
}
