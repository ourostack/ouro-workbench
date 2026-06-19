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

    func testNeedsRecoveryRunWaitsOnYou() {
        // A run that died and needs recovery is the operator's call, not "done".
        let e = entry(name: "Crashed", projectId: project.id, attention: .idle)
        let run = ProcessRun(entryId: e.id, status: .needsRecovery, startedAt: Date(timeIntervalSince1970: 10))
        let state = WorkspaceState(projects: [project], processEntries: [e], processRuns: [run])

        let list = SessionStatusList.make(from: state)

        XCTAssertEqual(list.waitingOnYou.map(\.name), ["Crashed"])
    }

    func testManualActionNeededRunWaitsOnYou() {
        let e = entry(name: "Manual", projectId: project.id, attention: .idle)
        let run = ProcessRun(entryId: e.id, status: .manualActionNeeded, startedAt: Date(timeIntervalSince1970: 10))
        let state = WorkspaceState(projects: [project], processEntries: [e], processRuns: [run])

        let list = SessionStatusList.make(from: state)

        XCTAssertEqual(list.waitingOnYou.map(\.name), ["Manual"])
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
        let run = ProcessRun(entryId: e.id, status: .running, startedAt: Date(timeIntervalSince1970: 10), pid: 4242)
        let state = WorkspaceState(projects: [project], processEntries: [e], processRuns: [run])

        let list = SessionStatusList.make(from: state)
        let row = try? XCTUnwrap(list.running.first)

        XCTAssertEqual(row?.owner, .agent(name: "slugger"))
        XCTAssertEqual(row?.workingDirectory, "/work/recipes")
        XCTAssertEqual(row?.id, e.id)
        XCTAssertEqual(row?.bucket, .running)
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
