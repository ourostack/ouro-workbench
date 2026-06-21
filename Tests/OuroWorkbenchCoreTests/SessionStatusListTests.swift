import XCTest
@testable import OuroWorkbenchCore

/// Tests for `SessionStatusList` — the pure projection from a `WorkspaceState`
/// into the three boss-forward buckets (running / waiting-on-you / done) that
/// the App's status list renders. Mirrors the `SessionSnapshot` fixture posture:
/// build a `WorkspaceState`, project, assert the bucket membership + ordering.
final class SessionStatusListTests: XCTestCase {
    private let project = WorkbenchProject(name: "Recipes", rootPath: "/work/recipes")

    private func entry(
        name: String,
        projectId: UUID,
        attention: AttentionState = .idle,
        isArchived: Bool = false,
        owner: SessionOwner = .human
    ) -> ProcessEntry {
        ProcessEntry(
            projectId: projectId,
            name: name,
            kind: .terminalAgent,
            executable: "claude",
            workingDirectory: "/work/recipes",
            isArchived: isArchived,
            attention: attention,
            owner: owner
        )
    }

    // MARK: - Bucket classification

    func testRunningEntryLandsInRunningBucket() {
        let e = entry(name: "Builder", projectId: project.id, attention: .active)
        let run = ProcessRun(entryId: e.id, status: .running, startedAt: Date(timeIntervalSince1970: 10))
        let state = WorkspaceState(projects: [project], processEntries: [e], processRuns: [run])

        let list = SessionStatusList.make(from: state)

        XCTAssertEqual(list.running.map(\.name), ["Builder"])
        XCTAssertTrue(list.waitingOnYou.isEmpty)
        XCTAssertTrue(list.done.isEmpty)
        XCTAssertEqual(list.running.first?.status, .running)
        XCTAssertEqual(list.running.first?.group, "Recipes")
    }

    func testAgentOwnedWaitingSessionIsNotWaitingOnYouWhileHumanOwnedOneIs() {
        // #U25b: an agent-owned session merely parked at its own loop's prompt
        // (attention waitingOnHuman) is the AGENT's turn, not the human's — it must
        // NOT land in the boss's waiting-on-you bucket. A human-owned waiting
        // session still does.
        let humanWaiting = entry(name: "HumanAsker", projectId: project.id, attention: .waitingOnHuman, owner: .human)
        let agentWaiting = entry(name: "AgentLoop", projectId: project.id, attention: .waitingOnHuman, owner: .agent(name: "slugger"))
        let agentBlocked = entry(name: "AgentStuck", projectId: project.id, attention: .blocked, owner: .agent(name: "slugger"))
        let state = WorkspaceState(
            projects: [project],
            processEntries: [humanWaiting, agentWaiting, agentBlocked],
            processRuns: [
                ProcessRun(entryId: humanWaiting.id, status: .running, startedAt: Date(timeIntervalSince1970: 10)),
                ProcessRun(entryId: agentWaiting.id, status: .running, startedAt: Date(timeIntervalSince1970: 10)),
                ProcessRun(entryId: agentBlocked.id, status: .running, startedAt: Date(timeIntervalSince1970: 10))
            ]
        )

        let list = SessionStatusList.make(from: state)

        XCTAssertEqual(list.waitingOnYou.map(\.name), ["HumanAsker"], "only the human-owned waiting session is waiting on you")
        // The agent-driven sessions are the agent's own active work → running.
        XCTAssertEqual(Set(list.running.map(\.name)), ["AgentLoop", "AgentStuck"])
    }

    func testAgentOwnedWaitingForInputRunIsTheAgentsTurnNotWaitingOnYou() {
        // #U25b: a run parked at a prompt (.waitingForInput) is the operator's turn
        // for a HUMAN-owned session, but the agent's own loop for an agent-owned one
        // (with calm attention) — so the agent-owned one is running, not waiting-on-you.
        let agent = entry(name: "AgentLoop", projectId: project.id, attention: .active, owner: .agent(name: "slugger"))
        let human = entry(name: "HumanShell", projectId: project.id, attention: .active, owner: .human)
        let state = WorkspaceState(
            projects: [project],
            processEntries: [agent, human],
            processRuns: [
                ProcessRun(entryId: agent.id, status: .waitingForInput, startedAt: Date(timeIntervalSince1970: 10)),
                ProcessRun(entryId: human.id, status: .waitingForInput, startedAt: Date(timeIntervalSince1970: 10))
            ]
        )

        let list = SessionStatusList.make(from: state)
        XCTAssertEqual(list.waitingOnYou.map(\.name), ["HumanShell"])
        XCTAssertEqual(list.running.map(\.name), ["AgentLoop"])
        // Pin both arms of the run-status branch at the seam.
        XCTAssertEqual(
            SessionStatusList.classify(attention: .active, owner: .agent(name: "x"), runStatus: .waitingForInput),
            .running
        )
        XCTAssertEqual(
            SessionStatusList.classify(attention: .active, owner: .human, runStatus: .waitingForInput),
            .waitingOnYou
        )
    }

    func testAgentOwnedNeedsBossReviewStillSurfacesAsWaitingOnYou() {
        // #U25b: a genuine boss-RAISED review item (needsBossReview) is a real
        // human-attention item even on an agent-owned session — suppression of the
        // agent's own loop must not hide a review the boss escalated.
        let agentReview = entry(name: "AgentReview", projectId: project.id, attention: .needsBossReview, owner: .agent(name: "slugger"))
        let state = WorkspaceState(
            projects: [project],
            processEntries: [agentReview],
            processRuns: [ProcessRun(entryId: agentReview.id, status: .running, startedAt: Date(timeIntervalSince1970: 10))]
        )

        let list = SessionStatusList.make(from: state)
        XCTAssertEqual(list.waitingOnYou.map(\.name), ["AgentReview"])
    }

    func testWaitingOnHumanAttentionLandsInWaitingBucketEvenWhenRunning() {
        // Attention that needs the human wins over a still-running process: the
        // operator must be told it's waiting on them, not buried under "running".
        let e = entry(name: "Asker", projectId: project.id, attention: .waitingOnHuman)
        let run = ProcessRun(entryId: e.id, status: .running, startedAt: Date(timeIntervalSince1970: 10))
        let state = WorkspaceState(projects: [project], processEntries: [e], processRuns: [run])

        let list = SessionStatusList.make(from: state)

        XCTAssertEqual(list.waitingOnYou.map(\.name), ["Asker"])
        XCTAssertTrue(list.running.isEmpty)
        XCTAssertTrue(list.done.isEmpty)
        XCTAssertTrue(list.waitingOnYou.first?.needsHuman ?? false)
    }

    func testNeedsBossReviewAndBlockedAlsoWaitOnYou() {
        let review = entry(name: "Review", projectId: project.id, attention: .needsBossReview)
        let blocked = entry(name: "Blocked", projectId: project.id, attention: .blocked)
        let state = WorkspaceState(projects: [project], processEntries: [review, blocked])

        let list = SessionStatusList.make(from: state)

        XCTAssertEqual(Set(list.waitingOnYou.map(\.name)), ["Review", "Blocked"])
    }

    func testWaitingForInputRunStatusWaitsOnYou() {
        // Even with neutral attention, a run that is parked at a prompt is the
        // operator's turn.
        let e = entry(name: "Prompted", projectId: project.id, attention: .idle)
        let run = ProcessRun(entryId: e.id, status: .waitingForInput, startedAt: Date(timeIntervalSince1970: 10))
        let state = WorkspaceState(projects: [project], processEntries: [e], processRuns: [run])

        let list = SessionStatusList.make(from: state)

        XCTAssertEqual(list.waitingOnYou.map(\.name), ["Prompted"])
        XCTAssertTrue(list.running.isEmpty)
        XCTAssertTrue(list.done.isEmpty)
    }

    func testExitedRunLandsInDoneBucket() {
        let e = entry(name: "Finished", projectId: project.id, attention: .idle)
        let run = ProcessRun(
            entryId: e.id,
            status: .exited,
            startedAt: Date(timeIntervalSince1970: 10),
            exitCode: 0
        )
        let state = WorkspaceState(projects: [project], processEntries: [e], processRuns: [run])

        let list = SessionStatusList.make(from: state)

        XCTAssertEqual(list.done.map(\.name), ["Finished"])
        XCTAssertTrue(list.running.isEmpty)
        XCTAssertTrue(list.waitingOnYou.isEmpty)
        XCTAssertEqual(list.done.first?.status, .exited)
        XCTAssertEqual(list.done.first?.exitCode, 0)
    }

    func testNeedsRecoveryWithCalmIdleAttentionDoesNotWaitOnYou() {
        // U8-1: a survivor kept running while Workbench was closed lives in
        // `.needsRecovery` with the calm `.idle` attention the reconciler
        // assigned, during the async reattach window. Bucketing it
        // waiting-on-you off the raw run status would re-create the exact
        // false-alarm U8a killed — on the operator side. It must NOT surface as
        // the operator's turn; it's settled, reconnecting.
        let e = entry(name: "Survivor", projectId: project.id, attention: .idle)
        let run = ProcessRun(entryId: e.id, status: .needsRecovery, startedAt: Date(timeIntervalSince1970: 10))
        let state = WorkspaceState(projects: [project], processEntries: [e], processRuns: [run])

        let list = SessionStatusList.make(from: state)

        XCTAssertTrue(list.waitingOnYou.isEmpty)
        XCTAssertEqual(list.done.map(\.name), ["Survivor"])
        // Pinned at the seam too, so the contract is unambiguous.
        XCTAssertEqual(
            SessionStatusList.classify(attention: .idle, owner: .human, runStatus: .needsRecovery),
            .done
        )
    }

    func testNeedsRecoveryWithNeedsBossReviewStillWaitsOnYou() {
        // A genuinely-lost manual-recovery session — the reconciler raises
        // `.needsBossReview` for it — still surfaces as the operator's turn.
        let e = entry(name: "Crashed", projectId: project.id, attention: .needsBossReview)
        let run = ProcessRun(entryId: e.id, status: .needsRecovery, startedAt: Date(timeIntervalSince1970: 10))
        let state = WorkspaceState(projects: [project], processEntries: [e], processRuns: [run])

        let list = SessionStatusList.make(from: state)

        XCTAssertEqual(list.waitingOnYou.map(\.name), ["Crashed"])
        XCTAssertEqual(
            SessionStatusList.classify(attention: .needsBossReview, owner: .human, runStatus: .needsRecovery),
            .waitingOnYou
        )
    }

    func testManualActionNeededRunConsultsAttention() {
        // Same contract for `.manualActionNeeded`: calm attention is settled,
        // a needs-you attention flag surfaces.
        let calm = entry(name: "CalmManual", projectId: project.id, attention: .idle)
        let calmRun = ProcessRun(entryId: calm.id, status: .manualActionNeeded, startedAt: Date(timeIntervalSince1970: 10))
        let flagged = entry(name: "FlaggedManual", projectId: project.id, attention: .needsBossReview)
        let flaggedRun = ProcessRun(entryId: flagged.id, status: .manualActionNeeded, startedAt: Date(timeIntervalSince1970: 10))
        let state = WorkspaceState(
            projects: [project],
            processEntries: [calm, flagged],
            processRuns: [calmRun, flaggedRun]
        )

        let list = SessionStatusList.make(from: state)

        XCTAssertEqual(list.waitingOnYou.map(\.name), ["FlaggedManual"])
        XCTAssertEqual(list.done.map(\.name), ["CalmManual"])
    }

    func testConfiguredNeverRunEntryLandsInDoneBucket() {
        // A session that has never run (no run, or an explicit `.configured`
        // run) is idle-and-ready — not running, not waiting; it belongs in the
        // settled "done / idle" bucket so the running list stays a true
        // "what's working right now".
        let neverRun = entry(name: "NeverRun", projectId: project.id, attention: .idle)
        let configuredEntry = entry(name: "Configured", projectId: project.id, attention: .idle)
        let configuredRun = ProcessRun(
            entryId: configuredEntry.id,
            status: .configured,
            startedAt: Date(timeIntervalSince1970: 10)
        )
        let state = WorkspaceState(
            projects: [project],
            processEntries: [neverRun, configuredEntry],
            processRuns: [configuredRun]
        )

        let list = SessionStatusList.make(from: state)

        XCTAssertEqual(Set(list.done.map(\.name)), ["NeverRun", "Configured"])
        XCTAssertTrue(list.running.isEmpty)
        XCTAssertTrue(list.waitingOnYou.isEmpty)
    }

    // MARK: - Latest run wins

    func testLatestRunDeterminesBucket() {
        // Older running run is superseded by a newer exited run → done.
        let e = entry(name: "Sequence", projectId: project.id, attention: .idle)
        let older = ProcessRun(entryId: e.id, status: .running, startedAt: Date(timeIntervalSince1970: 1))
        let newer = ProcessRun(
            entryId: e.id,
            status: .exited,
            startedAt: Date(timeIntervalSince1970: 2),
            exitCode: 0
        )
        let state = WorkspaceState(projects: [project], processEntries: [e], processRuns: [older, newer])

        let list = SessionStatusList.make(from: state)

        XCTAssertEqual(list.done.map(\.name), ["Sequence"])
        XCTAssertTrue(list.running.isEmpty)
    }

    // MARK: - Archived excluded

    func testArchivedEntriesExcludedByDefault() {
        let live = entry(name: "Live", projectId: project.id, attention: .active)
        let liveRun = ProcessRun(entryId: live.id, status: .running, startedAt: Date(timeIntervalSince1970: 10))
        let archived = entry(name: "Archived", projectId: project.id, attention: .active, isArchived: true)
        let archivedRun = ProcessRun(entryId: archived.id, status: .running, startedAt: Date(timeIntervalSince1970: 10))
        let state = WorkspaceState(
            projects: [project],
            processEntries: [live, archived],
            processRuns: [liveRun, archivedRun]
        )

        let list = SessionStatusList.make(from: state)

        XCTAssertEqual(list.running.map(\.name), ["Live"])
        XCTAssertTrue(list.all.allSatisfy { $0.name != "Archived" })
    }

    func testArchivedIncludedWhenRequested() {
        let archived = entry(name: "Archived", projectId: project.id, attention: .active, isArchived: true)
        let archivedRun = ProcessRun(entryId: archived.id, status: .running, startedAt: Date(timeIntervalSince1970: 10))
        let state = WorkspaceState(
            projects: [project],
            processEntries: [archived],
            processRuns: [archivedRun]
        )

        let list = SessionStatusList.make(from: state, includeArchived: true)

        XCTAssertEqual(list.running.map(\.name), ["Archived"])
    }

    // MARK: - Ordering

    func testRunningOrderedByMostRecentOutputThenStart() {
        // The freshest activity floats to the top of each bucket so the operator
        // reads "what moved most recently" first.
        let a = entry(name: "A", projectId: project.id, attention: .active)
        let b = entry(name: "B", projectId: project.id, attention: .active)
        let c = entry(name: "C", projectId: project.id, attention: .active)
        let runA = ProcessRun(
            entryId: a.id,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 1),
            lastOutputAt: Date(timeIntervalSince1970: 100)
        )
        let runB = ProcessRun(
            entryId: b.id,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 1),
            lastOutputAt: Date(timeIntervalSince1970: 300)
        )
        let runC = ProcessRun(
            entryId: c.id,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 1),
            lastOutputAt: Date(timeIntervalSince1970: 200)
        )
        let state = WorkspaceState(
            projects: [project],
            processEntries: [a, b, c],
            processRuns: [runA, runB, runC]
        )

        let list = SessionStatusList.make(from: state)

        XCTAssertEqual(list.running.map(\.name), ["B", "C", "A"])
    }

    func testOrderingFallsBackToNameWhenNoActivity() {
        // No run / no lastOutput → deterministic by name (case-insensitive) so
        // the list never reorders nondeterministically between renders.
        let zebra = entry(name: "zebra", projectId: project.id, attention: .idle)
        let apple = entry(name: "Apple", projectId: project.id, attention: .idle)
        let state = WorkspaceState(projects: [project], processEntries: [zebra, apple])

        let list = SessionStatusList.make(from: state)

        XCTAssertEqual(list.done.map(\.name), ["Apple", "zebra"])
    }

    // MARK: - Aggregate helpers

    func testAllConcatenatesBucketsAndCountsReport() {
        let runningE = entry(name: "Run", projectId: project.id, attention: .active)
        let runningRun = ProcessRun(entryId: runningE.id, status: .running, startedAt: Date(timeIntervalSince1970: 10))
        let waitingE = entry(name: "Wait", projectId: project.id, attention: .waitingOnHuman)
        let doneE = entry(name: "Done", projectId: project.id, attention: .idle)
        let doneRun = ProcessRun(entryId: doneE.id, status: .exited, startedAt: Date(timeIntervalSince1970: 10), exitCode: 0)
        let state = WorkspaceState(
            projects: [project],
            processEntries: [runningE, waitingE, doneE],
            processRuns: [runningRun, doneRun]
        )

        let list = SessionStatusList.make(from: state)

        XCTAssertEqual(list.all.map(\.name), ["Wait", "Run", "Done"])
        XCTAssertEqual(list.runningCount, 1)
        XCTAssertEqual(list.waitingOnYouCount, 1)
        XCTAssertEqual(list.doneCount, 1)
        XCTAssertFalse(list.isEmpty)
    }

    func testEmptyStateProducesEmptyList() {
        let list = SessionStatusList.make(from: WorkspaceState())

        XCTAssertTrue(list.running.isEmpty)
        XCTAssertTrue(list.waitingOnYou.isEmpty)
        XCTAssertTrue(list.done.isEmpty)
        XCTAssertTrue(list.all.isEmpty)
        XCTAssertTrue(list.isEmpty)
        XCTAssertEqual(list.runningCount, 0)
    }

    // MARK: - Row fidelity

    func testRowCarriesOwnerAndWorkingDirectory() {
        let e = entry(name: "Owned", projectId: project.id, attention: .active, owner: .agent(name: "slugger"))
        let run = ProcessRun(entryId: e.id, pid: 4242, status: .running, startedAt: Date(timeIntervalSince1970: 10))
        let state = WorkspaceState(projects: [project], processEntries: [e], processRuns: [run])

        let list = SessionStatusList.make(from: state)
        let row = try? XCTUnwrap(list.running.first)

        XCTAssertEqual(row?.owner, .agent(name: "slugger"))
        XCTAssertEqual(row?.workingDirectory, "/work/recipes")
        XCTAssertEqual(row?.id, e.id)
        XCTAssertEqual(row?.bucket, .running)
    }

    // MARK: - Tiebreaker coverage (every arm of `isFresher`)

    func testRowWithLastOutputSortsAheadOfRowWithout() {
        // One row has lastOutputAt, the other doesn't → the one with a timestamp
        // is fresher regardless of name. Exercises both nil-asymmetry arms.
        let withOut = entry(name: "Aaa", projectId: project.id, attention: .active)
        let withRun = ProcessRun(
            entryId: withOut.id,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 1),
            lastOutputAt: Date(timeIntervalSince1970: 500)
        )
        let none = entry(name: "Bbb", projectId: project.id, attention: .active)
        // `none` is running but has only a startedAt, no lastOutputAt.
        let noneRun = ProcessRun(entryId: none.id, status: .running, startedAt: Date(timeIntervalSince1970: 2))
        let state = WorkspaceState(
            projects: [project],
            processEntries: [none, withOut],
            processRuns: [withRun, noneRun]
        )

        let list = SessionStatusList.make(from: state)

        // The row WITH lastOutputAt sorts first even though its name ("Aaa")
        // would also win alphabetically — assert the timestamp arm by also
        // checking the reverse ordering below.
        XCTAssertEqual(list.running.map(\.name), ["Aaa", "Bbb"])
    }

    func testRowWithoutLastOutputSortsAfterRowWithIt() {
        // Reverse of the above so the OTHER nil-asymmetry arm is hit: the
        // timestamped row's NAME would lose alphabetically, proving the sort is
        // driven by the timestamp, not the name.
        let timestamped = entry(name: "Zzz", projectId: project.id, attention: .active)
        let timestampedRun = ProcessRun(
            entryId: timestamped.id,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 1),
            lastOutputAt: Date(timeIntervalSince1970: 500)
        )
        let plain = entry(name: "Aaa", projectId: project.id, attention: .active)
        let plainRun = ProcessRun(entryId: plain.id, status: .running, startedAt: Date(timeIntervalSince1970: 2))
        let state = WorkspaceState(
            projects: [project],
            processEntries: [plain, timestamped],
            processRuns: [timestampedRun, plainRun]
        )

        let list = SessionStatusList.make(from: state)

        XCTAssertEqual(list.running.map(\.name), ["Zzz", "Aaa"])
    }

    func testEqualLastOutputFallsBackToStartedAt() {
        // Same lastOutputAt → newer startedAt wins (the `l != r` startedAt arm).
        let a = entry(name: "A", projectId: project.id, attention: .active)
        let b = entry(name: "B", projectId: project.id, attention: .active)
        let shared = Date(timeIntervalSince1970: 500)
        let runA = ProcessRun(
            entryId: a.id,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 10),
            lastOutputAt: shared
        )
        let runB = ProcessRun(
            entryId: b.id,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 20),
            lastOutputAt: shared
        )
        let state = WorkspaceState(projects: [project], processEntries: [a, b], processRuns: [runA, runB])

        let list = SessionStatusList.make(from: state)

        XCTAssertEqual(list.running.map(\.name), ["B", "A"])
    }

    func testRowWithStartedAtSortsAheadOfRowWithout() {
        // Neither has lastOutputAt; one has startedAt (running), one has neither
        // (configured/never-run). Both land in `done`; the started one is fresher.
        let started = entry(name: "Zzz", projectId: project.id, attention: .idle)
        let startedRun = ProcessRun(
            entryId: started.id,
            status: .configured,
            startedAt: Date(timeIntervalSince1970: 99)
        )
        let neverRun = entry(name: "Aaa", projectId: project.id, attention: .idle)
        let state = WorkspaceState(
            projects: [project],
            processEntries: [neverRun, started],
            processRuns: [startedRun]
        )

        let list = SessionStatusList.make(from: state)

        // `started` has a startedAt and sorts ahead of `neverRun` despite the
        // name disadvantage (Zzz vs Aaa).
        XCTAssertEqual(list.done.map(\.name), ["Zzz", "Aaa"])
    }

    func testEqualEverythingFallsBackToId() {
        // Two sessions with identical name, no runs → deterministic by id.
        let lowId = ProcessEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            projectId: project.id,
            name: "Same",
            kind: .terminalAgent,
            executable: "claude",
            workingDirectory: "/work/recipes"
        )
        let highId = ProcessEntry(
            id: UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!,
            projectId: project.id,
            name: "Same",
            kind: .terminalAgent,
            executable: "claude",
            workingDirectory: "/work/recipes"
        )
        let state = WorkspaceState(projects: [project], processEntries: [highId, lowId])

        let list = SessionStatusList.make(from: state)

        XCTAssertEqual(list.done.map(\.id), [lowId.id, highId.id])
    }

    func testDuplicateProjectIdsCollapseToFirstGroupName() {
        // Two projects sharing the same id (degenerate but possible post-merge):
        // the group-name map keeps the FIRST — exercises the uniquingKeysWith
        // resolver.
        let sharedId = UUID()
        let first = WorkbenchProject(id: sharedId, name: "First", rootPath: "/a")
        let second = WorkbenchProject(id: sharedId, name: "Second", rootPath: "/b")
        let e = entry(name: "S", projectId: sharedId, attention: .active)
        let run = ProcessRun(entryId: e.id, status: .running, startedAt: Date(timeIntervalSince1970: 1))
        let state = WorkspaceState(
            projects: [first, second],
            processEntries: [e],
            processRuns: [run]
        )

        let list = SessionStatusList.make(from: state)

        XCTAssertEqual(list.running.first?.group, "First")
    }

    // MARK: - Direct comparator (both directions of each nil-asymmetry arm)

    private func row(name: String, started: Date? = nil, output: Date? = nil, id: UUID = UUID()) -> SessionStatusRow {
        SessionStatusRow(
            id: id,
            name: name,
            group: nil,
            owner: .human,
            bucket: .running,
            status: .running,
            attention: .active,
            needsHuman: false,
            workingDirectory: "/x",
            startedAt: started,
            lastOutputAt: output
        )
    }

    func testRowInitDefaultsAreNilWhenOmitted() {
        // Construct a row relying on every trailing default (pid/exitCode/
        // startedAt/lastOutputAt) so the default-argument thunks are exercised.
        let r = SessionStatusRow(
            id: UUID(),
            name: "Defaulted",
            group: nil,
            owner: .human,
            bucket: .done,
            status: .configured,
            attention: .idle,
            needsHuman: false,
            workingDirectory: "/x"
        )

        XCTAssertNil(r.pid)
        XCTAssertNil(r.exitCode)
        XCTAssertNil(r.startedAt)
        XCTAssertNil(r.lastOutputAt)
    }

    func testIsFresherLastOutputNilAsymmetryBothDirections() {
        let withOutput = row(name: "A", output: Date(timeIntervalSince1970: 10))
        let withoutOutput = row(name: "B")

        // lhs has output, rhs doesn't → fresher (true).
        XCTAssertTrue(SessionStatusList.isFresher(withOutput, withoutOutput))
        // lhs lacks output, rhs has it → not fresher (false) — the `return false` arm.
        XCTAssertFalse(SessionStatusList.isFresher(withoutOutput, withOutput))
    }

    func testIsFresherStartedAtDifferingNewerWins() {
        // No lastOutputAt on either → the comparator reaches the startedAt arm
        // with differing startedAt; the newer startedAt is fresher. This fires
        // the `{ return l > r }` body of the startedAt branch directly.
        let newer = row(name: "A", started: Date(timeIntervalSince1970: 20))
        let older = row(name: "B", started: Date(timeIntervalSince1970: 10))

        XCTAssertTrue(SessionStatusList.isFresher(newer, older))
        XCTAssertFalse(SessionStatusList.isFresher(older, newer))
    }

    func testIsFresherStartedAtNilAsymmetryBothDirections() {
        // Neither has lastOutputAt so the startedAt arm is reached.
        let withStart = row(name: "A", started: Date(timeIntervalSince1970: 10))
        let withoutStart = row(name: "B")

        XCTAssertTrue(SessionStatusList.isFresher(withStart, withoutStart))
        // The `return false` arm: lhs lacks startedAt, rhs has it.
        XCTAssertFalse(SessionStatusList.isFresher(withoutStart, withStart))
    }

    func testRowGroupNilWhenProjectMissing() {
        // Entry whose projectId has no matching project (orphaned) renders with
        // a nil group rather than crashing.
        let e = entry(name: "Orphan", projectId: UUID(), attention: .active)
        let run = ProcessRun(entryId: e.id, status: .running, startedAt: Date(timeIntervalSince1970: 10))
        let state = WorkspaceState(projects: [], processEntries: [e], processRuns: [run])

        let list = SessionStatusList.make(from: state)

        XCTAssertNil(list.running.first?.group)
    }
}
