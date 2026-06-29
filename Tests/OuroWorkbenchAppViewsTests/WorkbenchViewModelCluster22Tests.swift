#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 22 — the FINAL thin sliver before the genuine floor.
///
/// Drives the last directly-reachable pure-logic arms the view tests route around:
///   • `recoveryButtonTitle(for:)` (`:4559`) — the `.manualActionNeeded`→"Manual Recovery" arm
///     (the RecoverableEntryRow view tests document this as UNREACHABLE there — it routes to the
///     needs-you surface). Driven by seeding a `latestRun.status == .manualActionNeeded` so the
///     `RecoveryPlanner` derives `.manualActionNeeded`. Plus the `.noAction`→"Recover" arm (a
///     `.running` latest run) and the nil-plan→"Recover" guard (an entry absent from processEntries).
///   • `bossActionLivePrompt(for:)` (`:8087`) — the nil-transcript-tail guard → "" (an entry with no
///     transcript). The parse path needs a seeded on-disk transcript (carved — out of this thin batch).
///
/// After this batch the residual is overwhelmingly genuine-carve (detached-Task bodies, subprocess/
/// notification/NSApp lines, live-PTY NSView, infinite loops, source-pinned MCP overload, llvm-synth).
@MainActor
final class WorkbenchViewModelCluster22Tests: XCTestCase {

    private static let projectId = UUID(uuidString: "C22F1A00-0000-0000-0000-0000000000A1")!
    private static let wsId = UUID(uuidString: "C22F1A00-0000-0000-0000-0000000000B1")!
    private static let entryId = UUID(uuidString: "C22F1A00-0000-0000-0000-0000000000E1")!
    private static let runId = UUID(uuidString: "C22F1A00-0000-0000-0000-0000000000F1")!

    private func makeVM(entries: [ProcessEntry] = [], runs: [ProcessRun] = []) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmcluster22-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        try FileManager.default.createDirectory(at: agentBundles, withIntermediateDirectories: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            bossWatchEnabled: false,
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp")],
            processEntries: entries,
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: entries.map(\.id))],
            processRuns: runs)
        try WorkbenchStore(paths: paths).save(state)
        let m = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        m.launchTerminalSession = { _ in }
        m.chooseWorkspaceSaveURL = { _ in nil }
        m.chooseWorkspaceOpenURL = { _ in nil }
        m.terminateApp = {}
        return m
    }

    private func entry(trust: ProcessTrust = .trusted, archived: Bool = false) -> ProcessEntry {
        ProcessEntry(
            id: Self.entryId, projectId: Self.projectId, name: "build", kind: .shell,
            executable: "/bin/zsh", workingDirectory: "/tmp", trust: trust, isArchived: archived)
    }

    // MARK: - recoveryButtonTitle arms the view tests route around

    /// A `latestRun.status == .manualActionNeeded` → the planner derives `.manualActionNeeded` →
    /// the "Manual Recovery" title arm (documented UNREACHABLE in the RecoverableEntryRow view).
    func testRecoveryButtonTitle_manualActionNeeded() throws {
        let e = entry()
        let run = ProcessRun(id: Self.runId, entryId: Self.entryId, status: .manualActionNeeded)
        let m = try makeVM(entries: [e], runs: [run])
        XCTAssertEqual(m.recoveryButtonTitle(for: e), "Manual Recovery",
                       "a manual-action-needed latest run → the Manual Recovery title")
    }

    /// A `.running` latest run → the planner's `.noAction` (status is not needsRecovery) → "Recover".
    func testRecoveryButtonTitle_runningRun_noAction() throws {
        let e = entry()
        let run = ProcessRun(id: Self.runId, entryId: Self.entryId, status: .running)
        let m = try makeVM(entries: [e], runs: [run])
        XCTAssertEqual(m.recoveryButtonTitle(for: e), "Recover",
                       "a running latest run → the no-action Recover title")
    }

    /// An entry with NO prior run → `recoveryPlan(for:)` returns nil → the nil-plan guard → "Recover".
    func testRecoveryButtonTitle_noPlan_recover() throws {
        let e = entry()
        let m = try makeVM(entries: [e], runs: [])
        XCTAssertEqual(m.recoveryButtonTitle(for: e), "Recover",
                       "an entry with no recovery plan → the nil-plan Recover title")
    }

    // MARK: - bossActionLivePrompt nil-transcript guard

    /// An entry with no transcript tail → the nil-tail guard returns "".
    func testBossActionLivePrompt_noTranscript_isEmpty() throws {
        let e = entry()
        let m = try makeVM(entries: [e], runs: [])
        XCTAssertEqual(m.bossActionLivePrompt(for: e), "",
                       "no transcript tail → the live-prompt guard returns empty")
    }
}
#endif
