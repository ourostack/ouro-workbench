import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchAttentionQueueRendererTests: XCTestCase {
    private let renderer = WorkbenchAttentionQueueRenderer()

    private func entry(
        name: String,
        attention: AttentionState,
        reason: String? = nil,
        owner: SessionOwner = .human,
        projectId: UUID
    ) -> ProcessEntry {
        ProcessEntry(
            projectId: projectId,
            name: name,
            kind: .terminalAgent,
            executable: "claude",
            workingDirectory: "/tmp/proj",
            attention: attention,
            attentionReason: reason,
            owner: owner
        )
    }

    func testEmptyQueueWhenNothingNeedsAHuman() {
        let project = WorkbenchProject(name: "Proj", rootPath: "/tmp/proj")
        let idle = entry(name: "idle", attention: .idle, projectId: project.id)
        let active = entry(name: "active", attention: .active, projectId: project.id)
        let state = WorkspaceState(projects: [project], processEntries: [idle, active], processRuns: [])

        XCTAssertTrue(renderer.queue(state: state).isEmpty)
    }

    func testReturnsOnlyNeedsHumanSessionsOrderedBlockedFirst() {
        let project = WorkbenchProject(name: "Proj", rootPath: "/tmp/proj")
        let waiting = entry(name: "waiting", attention: .waitingOnHuman, reason: "Approve?", projectId: project.id)
        let blocked = entry(name: "blocked", attention: .blocked, reason: "Build failed", projectId: project.id)
        let review = entry(name: "review", attention: .needsBossReview, projectId: project.id)
        let idle = entry(name: "idle", attention: .idle, projectId: project.id)
        let state = WorkspaceState(
            projects: [project],
            processEntries: [waiting, idle, review, blocked],
            processRuns: []
        )

        let queue = renderer.queue(state: state)
        // Idle is excluded; the three needs-human rows are ordered blocked →
        // waitingOnHuman → needsBossReview.
        XCTAssertEqual(queue.map(\.name), ["blocked", "waiting", "review"])
        XCTAssertEqual(queue.map(\.attention), ["blocked", "waitingOnHuman", "needsBossReview"])
        // Per-session triage context the boss reads.
        XCTAssertEqual(queue[0].attentionReason, "Build failed")
        XCTAssertEqual(queue[1].attentionReason, "Approve?")
        XCTAssertEqual(queue[0].group, "Proj")
    }

    func testWithinBucketOrdersFreshestFirst() {
        let project = WorkbenchProject(name: "Proj", rootPath: "/tmp/proj")
        let older = entry(name: "older", attention: .waitingOnHuman, projectId: project.id)
        let newer = entry(name: "newer", attention: .waitingOnHuman, projectId: project.id)
        let state = WorkspaceState(
            projects: [project],
            processEntries: [older, newer],
            processRuns: [
                ProcessRun(entryId: older.id, status: .waitingForInput, startedAt: Date(timeIntervalSince1970: 1_000), lastOutputAt: Date(timeIntervalSince1970: 1_000)),
                ProcessRun(entryId: newer.id, status: .waitingForInput, startedAt: Date(timeIntervalSince1970: 9_000), lastOutputAt: Date(timeIntervalSince1970: 9_000))
            ]
        )

        XCTAssertEqual(renderer.queue(state: state).map(\.name), ["newer", "older"])
    }

    func testAttachesInlinePromptSnippetForWaitingRow() {
        let project = WorkbenchProject(name: "Proj", rootPath: "/tmp/proj")
        let waiting = entry(name: "waiting", attention: .waitingOnHuman, projectId: project.id)
        let state = WorkspaceState(projects: [project], processEntries: [waiting], processRuns: [])

        let queue = renderer.queue(state: state, promptSnippets: [waiting.id: "Continue? (y/n)"])
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue[0].attentionPrompt, "Continue? (y/n)")
    }

    func testAgentOwnedWaitingSessionIsExcludedButBossReviewIsKept() {
        // #U25b reconciliation: an agent-owned session parked at its own loop's
        // prompt is the agent's turn, so it's NOT in the human attention queue;
        // a genuine boss-raised review on an agent-owned session still is.
        let project = WorkbenchProject(name: "Proj", rootPath: "/tmp/proj")
        let agentWaiting = entry(name: "agent-loop", attention: .waitingOnHuman, owner: .agent(name: "slugger"), projectId: project.id)
        let agentBlocked = entry(name: "agent-stuck", attention: .blocked, owner: .agent(name: "slugger"), projectId: project.id)
        let agentReview = entry(name: "agent-review", attention: .needsBossReview, owner: .agent(name: "slugger"), projectId: project.id)
        let humanWaiting = entry(name: "human-asker", attention: .waitingOnHuman, owner: .human, projectId: project.id)
        let state = WorkspaceState(
            projects: [project],
            processEntries: [agentWaiting, agentBlocked, agentReview, humanWaiting],
            processRuns: []
        )

        let queue = renderer.queue(state: state)
        XCTAssertEqual(Set(queue.map(\.name)), ["human-asker", "agent-review"])
        XCTAssertFalse(queue.contains { $0.name == "agent-loop" })
        XCTAssertFalse(queue.contains { $0.name == "agent-stuck" })
    }

    func testReadbackReflectsAStateChange() {
        // Before: the session is waiting and appears in the queue. After the boss
        // queues a fix and the session is no longer waiting, a re-read shows the
        // queue cleared — the readback reflects the state change.
        let project = WorkbenchProject(name: "Proj", rootPath: "/tmp/proj")
        let waiting = entry(name: "waiting", attention: .waitingOnHuman, projectId: project.id)
        let before = WorkspaceState(projects: [project], processEntries: [waiting], processRuns: [])
        XCTAssertEqual(renderer.queue(state: before).map(\.name), ["waiting"])

        var cleared = waiting
        cleared.attention = .active
        let after = WorkspaceState(projects: [project], processEntries: [cleared], processRuns: [])
        XCTAssertTrue(renderer.queue(state: after).isEmpty)
    }

    /// A snapshot stub for exercising the internal `triageOrder` comparator
    /// directly — including the tiebreak levels and the defensive rank arm the
    /// public `queue(...)` filter can't reach (it only admits the three
    /// needs-human states).
    private func snapshot(
        id: String,
        name: String,
        attention: String,
        startedAt: Date? = nil,
        lastOutputAt: Date? = nil
    ) -> SessionSnapshot {
        SessionSnapshot(
            id: id,
            name: name,
            owner: SessionOwnerSnapshot(kind: "human"),
            kind: "terminalAgent",
            status: "waitingForInput",
            attention: attention,
            needsHuman: true,
            trust: "untrusted",
            autoResume: false,
            isArchived: false,
            isPinned: false,
            workingDirectory: "/tmp",
            startedAt: startedAt,
            lastOutputAt: lastOutputAt
        )
    }

    func testTriageOrderFallsBackThroughStartedNameAndId() {
        let t = Date(timeIntervalSince1970: 5_000)
        // Same attention + same (missing) lastOutputAt: a present startedAt sorts
        // ahead of a missing one.
        let withStarted = snapshot(id: "a", name: "z", attention: "blocked", startedAt: t)
        let noStarted = snapshot(id: "b", name: "a", attention: "blocked")
        XCTAssertTrue(WorkbenchAttentionQueueRenderer.triageOrder(withStarted, noStarted))

        // Same attention + same timestamps: case-insensitive name breaks the tie.
        let nameA = snapshot(id: "a", name: "apple", attention: "blocked", startedAt: t, lastOutputAt: t)
        let nameB = snapshot(id: "b", name: "banana", attention: "blocked", startedAt: t, lastOutputAt: t)
        XCTAssertTrue(WorkbenchAttentionQueueRenderer.triageOrder(nameA, nameB))

        // Same attention + timestamps + name: id is the final total-order tiebreak.
        let idA = snapshot(id: "aaa", name: "same", attention: "blocked", startedAt: t, lastOutputAt: t)
        let idB = snapshot(id: "bbb", name: "same", attention: "blocked", startedAt: t, lastOutputAt: t)
        XCTAssertTrue(WorkbenchAttentionQueueRenderer.triageOrder(idA, idB))
        XCTAssertFalse(WorkbenchAttentionQueueRenderer.triageOrder(idB, idA))
    }

    func testTriageOrderDefensiveRankSortsUnexpectedAttentionLast() {
        // An attention value outside the three needs-human states (defensive: the
        // public filter never admits one) sorts after every real queue item.
        let real = snapshot(id: "a", name: "real", attention: "needsBossReview")
        let unexpected = snapshot(id: "b", name: "weird", attention: "idle")
        XCTAssertTrue(WorkbenchAttentionQueueRenderer.triageOrder(real, unexpected))
        XCTAssertFalse(WorkbenchAttentionQueueRenderer.triageOrder(unexpected, real))
    }

    func testNeedsHumanAttentionSetMatchesNeedsHumanStates() {
        // The queue's filter set is exactly the AttentionState raw values whose
        // needsHuman is true — single-sourced so the alias and the
        // workbench_sessions(attention:) filter can never disagree.
        let needsHuman = Set(
            [AttentionState.idle, .active, .waitingOnHuman, .blocked, .needsBossReview]
                .filter(\.needsHuman)
                .map(\.rawValue)
        )
        XCTAssertEqual(WorkbenchAttentionQueueRenderer.needsHumanAttention, needsHuman)
    }
}
