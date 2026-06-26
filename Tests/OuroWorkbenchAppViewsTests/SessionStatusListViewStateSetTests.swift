#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C10-1 — the boss-forward session-status list (`SessionStatusListView` `:7612`) and its two
/// descended children `SessionStatusBucketSection` (`:7670`) + `SessionStatusRowView` (`:7699`).
/// All three are exercised by snapshotting the LIST: ViewInspector descends the plain
/// `VStack`/`ForEach` composition (the children are NOT behind a `.contextMenu{}`/`.popover{}`,
/// so the C5-recipe standalone carve does not apply — descending the real parent IS the
/// legitimate seam, and matches exactly how production composes them).
///
/// **Provenance (P2).** The list is a pure projection: `SessionStatusList.make(from: model.state)`.
/// Each fixture is a real `WorkspaceState` (process entries + runs) persisted through the
/// `makeVM` store seam (AN-001 temp `agentBundlesURL` dual-injection), so every bucket is the
/// GENUINE classification the Core producer emits — never a hand-assembled list. The bucket a
/// session lands in is driven by `SessionStatusList.classify(attention:owner:runStatus:)`:
///   - `.waitingOnYou` — a human-owned entry with `.waitingOnHuman` attention.
///   - `.running`      — latest run `.running`, calm attention.
///   - `.done`         — latest run `.exited` (carries an exit code), calm attention.
///
/// **Path-leak (P3).** `SessionStatusRowView.detailLine` renders `row.workingDirectory` verbatim
/// for the waiting bucket (and as the running/done fallback) → a FIXED `/tmp/u4` working dir
/// keeps any machine path out of the tree, defended by `!tree.contains("/Users/")`. The row
/// also renders `pid`/`exitCode` (deterministic integers) for the running/done buckets.
///
/// **No clock surface.** The list renders no timestamp (the `startedAt`/`lastOutputAt` dates feed
/// only the Core sort key, never a `Text`) → no cross-TZ proof needed for this view.
@MainActor
final class SessionStatusListViewStateSetTests: XCTestCase {

    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
    private static let waitingId = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
    private static let runningId = UUID(uuidString: "22222222-0000-0000-0000-000000000002")!
    private static let doneId = UUID(uuidString: "33333333-0000-0000-0000-000000000003")!
    private static let runId = UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000A1")!
    /// Fixed epochs only feed the Core sort key (never a rendered `Text`) — pinned so the
    /// freshest-first ordering is byte-stable between renders.
    private static let started = Date(timeIntervalSince1970: 1_767_323_000)

    /// Build a hermetic VM (AN-001 temp `agentBundlesURL` dual-injection), then assign the
    /// fixture `state` to the model's LIVE `@Published var state` — the EXACT property
    /// `SessionStatusListView` reads (`SessionStatusList.make(from: model.state)`). The status
    /// list is a live projection of the current `state`, so assigning it directly IS the real
    /// production seam (the same direct-`@Published` injection `bossWatchChangeSummaries` /
    /// `transcriptSearchResults` use). NB — the VM's `init→load()` runs the one-time
    /// `startupRecoveryReconciler` (which would flip a persisted `.running` run to an orphaned
    /// `.needsRecovery`, a genuine startup transform, NOT part of the status-list read path);
    /// assigning `state` post-construction is what gives a deterministic, live status snapshot.
    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c10status-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
        model.state = state
        return model
    }

    private func entry(id: UUID, name: String, attention: AttentionState = .idle) -> ProcessEntry {
        ProcessEntry(
            id: id, projectId: Self.projectId, name: name,
            kind: .shell, executable: "/bin/zsh", workingDirectory: "/tmp/u4",
            attention: attention
        )
    }

    /// The project provides the "group" label rendered next to each session name.
    private func project() -> WorkbenchProject {
        WorkbenchProject(id: Self.projectId, name: "alpha", rootPath: "/tmp/u4")
    }

    private func view(state: WorkspaceState) throws -> SessionStatusListView {
        SessionStatusListView(model: try makeVM(state: state))
    }

    // MARK: - Enumerated state-set

    /// EMPTY — no sessions → `SessionStatusList.isEmpty` → the whole view renders nothing.
    func testList_empty_rendersNothing() throws {
        let view = try view(state: WorkspaceState(projects: [project()]))
        XCTAssertTrue(SessionStatusList.make(from: view.model.state).isEmpty,
                      "provenance: no entries → an empty status list")
        try assertViewSnapshot(of: view, named: "SessionStatusListView.empty")
    }

    /// WAITING-ON-YOU only — a human-owned `.waitingOnHuman` session → the orange bucket
    /// renders, the running/done buckets self-hide.
    func testList_waitingOnYou() throws {
        let e = entry(id: Self.waitingId, name: "deploy-runner", attention: .waitingOnHuman)
        let state = WorkspaceState(projects: [project()], processEntries: [e])
        let view = try view(state: state)
        let list = SessionStatusList.make(from: view.model.state)
        XCTAssertEqual(list.waitingOnYouCount, 1, "provenance: waitingOnHuman → waitingOnYou bucket")
        XCTAssertEqual(list.runningCount, 0)
        XCTAssertEqual(list.doneCount, 0)
        try assertViewSnapshot(of: view, named: "SessionStatusListView.waitingOnYou")
    }

    /// RUNNING only — a calm session whose latest run is `.running` (carries a pid) → the green
    /// bucket renders with the "pid N" detail line.
    func testList_running() throws {
        let e = entry(id: Self.runningId, name: "build")
        let run = ProcessRun(id: Self.runId, entryId: Self.runningId, pid: 4242,
                             status: .running, startedAt: Self.started)
        let state = WorkspaceState(projects: [project()], processEntries: [e], processRuns: [run])
        let view = try view(state: state)
        let list = SessionStatusList.make(from: view.model.state)
        XCTAssertEqual(list.runningCount, 1, "provenance: a .running latest run → running bucket")
        XCTAssertEqual(list.running.first?.pid, 4242, "provenance: the pid surfaces on the row")
        try assertViewSnapshot(of: view, named: "SessionStatusListView.running")
    }

    /// DONE only — a calm session whose latest run `.exited` with an exit code → the secondary
    /// "Done" bucket renders with the "exited N" detail line.
    func testList_done() throws {
        let e = entry(id: Self.doneId, name: "tests")
        let run = ProcessRun(id: Self.runId, entryId: Self.doneId, status: .exited,
                             startedAt: Self.started, exitCode: 0)
        let state = WorkspaceState(projects: [project()], processEntries: [e], processRuns: [run])
        let view = try view(state: state)
        let list = SessionStatusList.make(from: view.model.state)
        XCTAssertEqual(list.doneCount, 1, "provenance: an .exited latest run → done bucket")
        XCTAssertEqual(list.done.first?.exitCode, 0, "provenance: the exit code surfaces")
        try assertViewSnapshot(of: view, named: "SessionStatusListView.done")
    }

    /// MIXED — all three buckets populated at once (the full layout: every bucket header + row).
    func testList_mixed_allThreeBuckets() throws {
        let waiting = entry(id: Self.waitingId, name: "deploy-runner", attention: .waitingOnHuman)
        let running = entry(id: Self.runningId, name: "build")
        let done = entry(id: Self.doneId, name: "tests")
        let runningRun = ProcessRun(id: Self.runId, entryId: Self.runningId, pid: 4242,
                                    status: .running, startedAt: Self.started)
        let doneRun = ProcessRun(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000A2")!,
                                 entryId: Self.doneId, status: .exited,
                                 startedAt: Self.started, exitCode: 2)
        let state = WorkspaceState(
            projects: [project()],
            processEntries: [waiting, running, done],
            processRuns: [runningRun, doneRun]
        )
        let view = try view(state: state)
        let list = SessionStatusList.make(from: view.model.state)
        XCTAssertEqual([list.waitingOnYouCount, list.runningCount, list.doneCount], [1, 1, 1],
                       "provenance: one session in each bucket")
        try assertViewSnapshot(of: view, named: "SessionStatusListView.mixed")
    }

    // MARK: - Path-leak defense (P3)

    func testList_pathLeakDefense_noMachinePathInTree() throws {
        let waiting = entry(id: Self.waitingId, name: "deploy-runner", attention: .waitingOnHuman)
        let state = WorkspaceState(projects: [project()], processEntries: [waiting])
        let tree = try ViewSnapshotHost.snapshotText(of: try view(state: state))
        XCTAssertTrue(tree.contains("/tmp/u4"), "the fixed working dir is the rendered detail:\n\(tree)")
        XCTAssertFalse(tree.contains("/Users/"), "no /Users/ machine-path leak:\n\(tree)")
        XCTAssertFalse(tree.contains("/var/folders/"), "no temp-dir path leak:\n\(tree)")
    }

    // MARK: - Determinism (P3)

    func testList_determinism_byteIdenticalTwice() throws {
        let running = entry(id: Self.runningId, name: "build")
        let run = ProcessRun(id: Self.runId, entryId: Self.runningId, pid: 4242,
                             status: .running, startedAt: Self.started)
        let state = WorkspaceState(projects: [project()], processEntries: [running], processRuns: [run])
        let a = try ViewSnapshotHost.snapshotText(of: try view(state: state))
        let b = try ViewSnapshotHost.snapshotText(of: try view(state: state))
        XCTAssertEqual(a, b, "the status list must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The bucket a session lands in (and thus which header + detail line renders) is driven by
    /// the real attention/run-status seam: a waiting session shows "Waiting on you" + its working
    /// dir; flipping it to a running run moves it to the "Running" bucket with a "pid" detail.
    func testList_negativeControl_bucketFlipsTree() throws {
        let waitingState = WorkspaceState(
            projects: [project()],
            processEntries: [entry(id: Self.waitingId, name: "deploy-runner", attention: .waitingOnHuman)]
        )
        let runningState = WorkspaceState(
            projects: [project()],
            processEntries: [entry(id: Self.waitingId, name: "deploy-runner")],
            processRuns: [ProcessRun(id: Self.runId, entryId: Self.waitingId, pid: 99,
                                     status: .running, startedAt: Self.started)]
        )
        let waiting = try ViewSnapshotHost.snapshotText(of: try view(state: waitingState))
        let running = try ViewSnapshotHost.snapshotText(of: try view(state: runningState))

        XCTAssertNotEqual(waiting, running, "the bucket classification must flip the tree")
        XCTAssertTrue(waiting.contains("Waiting on you"), "waiting: the orange bucket header:\n\(waiting)")
        XCTAssertFalse(waiting.contains("pid"), "waiting: no pid detail (working-dir fallback)")
        XCTAssertTrue(running.contains("Running"), "running: the green bucket header:\n\(running)")
        XCTAssertTrue(running.contains("pid 99"), "running: the pid detail line renders:\n\(running)")
        XCTAssertFalse(running.contains("Waiting on you"), "running: not the waiting bucket")
    }

    /// The summary line is the Core counts ("N waiting · N running · N done") — a real
    /// data-driven value that changes with the buckets.
    func testList_negativeControl_summaryLineReflectsCounts() throws {
        let state = WorkspaceState(
            projects: [project()],
            processEntries: [entry(id: Self.waitingId, name: "a", attention: .waitingOnHuman)]
        )
        let tree = try ViewSnapshotHost.snapshotText(of: try view(state: state))
        XCTAssertTrue(tree.contains("1 waiting · 0 running · 0 done"),
                      "the summary line reflects the real counts:\n\(tree)")
    }
}
#endif
