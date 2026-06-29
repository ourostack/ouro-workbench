#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 13 — the FINAL mop-up: the last genuinely-drivable pure-logic
/// arms left in the residual before the irreducible machinery floor.
///
/// Drives:
///   • `windowTitle` (`:4300`) — the title-composition computed property. Every
///     focus arm (agent / group+entry / project / empty) × every final-format arm
///     (both-empty → appName, focus-empty → "app — boss", full → "app — boss — focus").
///   • `stepTerminalSearch` (`:2623`) — the no-active-session GUARD arm (sets
///     `terminalSearchHasResult = false`, returns false). (The live-find arms —
///     empty-query + find-next/prev — require a live `TerminalSessionController`
///     SwiftTerm PTY; that is CARVED: see the headless-hang note below.)
///   • `exportWorkspaceConfig` (`:3538`) — the three working-directory arms
///     (== root → nil, under-root → relative, else → absolute) + the group/root
///     projection.
///   • `presentSaveWorkspacePanel` (`:3572`) — the no-project GUARD + the
///     no-terminals GUARD (both return BEFORE the `NSSavePanel` construction). (The
///     write path constructs an `NSSavePanel`; that is CARVED — see the note below.)
///   • `flushPendingOutput` (`:9513`, widened private→internal) — the no-pending
///     GUARD arm (the per-run `lastOutputAt` mutate fold requires `markOutput`, which
///     arms a `Task.sleep(2s)` debounce; that is CARVED — see the note below).
///   • `restoreDetailLayout` (`:10165`, exercised via `load()` at init) — the
///     persisted-split-present arm (a seeded `state.detailLayout` restores the
///     split) + the no-layout single-pane arm.
///
/// HEADLESS-HANG CARVE (cluster-5 condition, widened): five originally-planned arms
/// were DROPPED from this class because, IN AGGREGATE, they deadlock the headless
/// xctest harness AT STARTUP (0% CPU, zero "Test Case started" — reproduced cleanly
/// on CI and locally; the same class runs fine in 1-3-test subsets, so it's a
/// count-sensitive load-time deadlock from the live AppKit/PTY/sleep-Task resources):
///   - `stepTerminalSearch` empty-query + non-empty-query (live `TerminalSessionController`
///     SwiftTerm PTY);
///   - `presentSaveWorkspacePanel` write + cancelled paths (live `NSSavePanel()` construct);
///   - `markOutput`→`flushPendingOutput` stamp paths (the `scheduleOutputFlush` `Task.sleep`
///     debounce leaves armed Tasks).
/// Those arms' value-flows are GENUINE machinery-adjacent (live PTY find / AppKit save
/// panel / async debounce) and are documented in the allowlist floor; this class keeps
/// every PURE-logic arm, which runs deterministically.
@MainActor
final class WorkbenchViewModelFinalMopupTests: XCTestCase {

    private static let projectId = UUID(uuidString: "C13F1A00-0000-0000-0000-0000000000A1")!
    private static let entryId = UUID(uuidString: "C13F1A00-0000-0000-0000-0000000000E1")!
    private static let entry2Id = UUID(uuidString: "C13F1A00-0000-0000-0000-0000000000E2")!
    private static let wsId = UUID(uuidString: "C13F1A00-0000-0000-0000-0000000000B1")!

    private func makeVM(
        entries: [ProcessEntry] = [],
        runs: [ProcessRun] = [],
        boss: String = "boss",
        rootPath: String = "/tmp/vmmopup",
        withProject: Bool = true,
        detailLayout: PaneLayoutState? = nil
    ) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmmopup-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        // `selectedProject` falls back to `state.projects.first`, so an "empty focus"
        // window-title arm is only reachable with NO projects at all.
        let projects = withProject
            ? [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: rootPath)]
            : []
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: boss),
            bossWatchEnabled: false,
            projects: projects,
            processEntries: entries,
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: entries.map(\.id))],
            processRuns: runs,
            detailLayout: detailLayout)
        try WorkbenchStore(paths: paths).save(state)
        let m = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        m.launchTerminalSession = { _ in }
        // Headless-safety: never let a test reach the REAL NSSavePanel/NSOpenPanel
        // `runModal()` — that blocks the run loop forever in a windowless xctest
        // (the deadlock that wedged this class at startup). The save-panel value-flow
        // tests that actually exercise the write inject their own non-nil URL; these
        // defaults just guarantee the guard/no-op paths can't hang on a live modal.
        m.chooseWorkspaceSaveURL = { _ in nil }
        m.chooseWorkspaceOpenURL = { _ in nil }
        return m
    }

    private func entry(
        id: UUID = entryId, name: String = "build", workingDirectory: String = "/tmp/vmmopup"
    ) -> ProcessEntry {
        ProcessEntry(id: id, projectId: Self.projectId, name: name, kind: .shell,
                     executable: "/bin/zsh", workingDirectory: workingDirectory, trust: .trusted)
    }

    // MARK: - windowTitle

    func testWindowTitle_bossAndProjectFocus() throws {
        let m = try makeVM()
        // No selected entry/agent → focus is the selected project's name.
        XCTAssertEqual(m.windowTitle, "Ouro Workbench — boss — Home",
                       "project focus composes app — boss — group")
    }

    func testWindowTitle_emptyBossAndNoFocus_isAppNameOnly() throws {
        let m = try makeVM(boss: "", withProject: false)
        // `load()` bootstraps a default project even from an empty seed, so clear
        // projects directly to reach the empty-focus arm (`selectedProject` == nil).
        m.state.projects = []
        m.state.boss = BossAgentSelection(agentName: "")
        m.selectedEntryID = nil
        m.selectedAgentName = nil
        XCTAssertEqual(m.windowTitle, "Ouro Workbench",
                       "empty boss + empty focus (no project) → bare app name")
    }

    func testWindowTitle_bossButNoFocus_isAppDashBoss() throws {
        let m = try makeVM(withProject: false)
        // `load()` bootstraps a default project even from an empty seed; clear it to
        // reach the empty-focus arm with the boss still set.
        m.state.projects = []
        m.selectedEntryID = nil
        m.selectedAgentName = nil
        XCTAssertEqual(m.windowTitle, "Ouro Workbench — boss",
                       "boss set + empty focus (no project) → app — boss")
    }

    func testWindowTitle_entryFocus_withGroupPrefix() throws {
        let m = try makeVM(entries: [entry(name: "deploy")])
        m.selectedAgentName = nil
        m.selectedEntryID = Self.entryId
        // selectedEntry resolves → focus = "<group> — <entry>"
        XCTAssertEqual(m.windowTitle, "Ouro Workbench — boss — Home — deploy",
                       "entry focus composes group — entry")
    }

    func testWindowTitle_agentFocus_takesPrecedence() throws {
        let m = try makeVM(entries: [entry()])
        let agentDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmmopup-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        m.ouroAgents.append(OuroAgentRecord(
            name: "scout", bundlePath: agentDir.path,
            configPath: agentDir.appendingPathComponent("agent.json").path,
            status: .ready, detail: "ready"))
        m.selectedAgentName = "scout"
        XCTAssertEqual(m.windowTitle, "Ouro Workbench — boss — Agent: scout",
                       "a resolvable selected agent wins the focus slot")
    }

    // MARK: - stepTerminalSearch (the no-session guard — the live-find arms are carved)

    func testStepTerminalSearch_noActiveSession_returnsFalseAndClearsResult() throws {
        let m = try makeVM(entries: [entry()])
        m.terminalSearchHasResult = true
        let hit = m.stepTerminalSearch(direction: .next)
        XCTAssertFalse(hit, "no active session → no search result")
        XCTAssertFalse(m.terminalSearchHasResult, "the guard arm clears terminalSearchHasResult")
    }

    // MARK: - exportWorkspaceConfig

    func testExportWorkspaceConfig_workingDirectoryArms() throws {
        let root = "/tmp/vmmopup-root"
        let m = try makeVM(
            entries: [
                entry(id: Self.entryId, name: "at-root", workingDirectory: root),
                entry(id: Self.entry2Id, name: "under-root", workingDirectory: root + "/sub/dir"),
            ],
            rootPath: root)
        let project = m.state.projects.first { $0.id == Self.projectId }!
        let config = m.exportWorkspaceConfig(for: project)
        XCTAssertEqual(config.group, "Home")
        XCTAssertEqual(config.rootPath, root)
        let byName = Dictionary(uniqueKeysWithValues: config.terminals.map { ($0.name, $0) })
        XCTAssertNil(byName["at-root"]?.workingDirectory,
                     "a terminal at the root collapses its working directory to nil")
        XCTAssertEqual(byName["under-root"]?.workingDirectory, "sub/dir",
                       "a terminal under the root stores a relative working directory")
    }

    func testExportWorkspaceConfig_absoluteWhenOutsideRoot() throws {
        let m = try makeVM(
            entries: [entry(name: "elsewhere", workingDirectory: "/var/other/place")],
            rootPath: "/tmp/vmmopup-root")
        let project = m.state.projects.first { $0.id == Self.projectId }!
        let config = m.exportWorkspaceConfig(for: project)
        XCTAssertEqual(config.terminals.first?.workingDirectory, "/var/other/place",
                       "a terminal outside the root keeps its absolute working directory")
    }

    // MARK: - presentSaveWorkspacePanel (the guards — the NSSavePanel write path is carved)

    func testPresentSaveWorkspacePanel_noProject_setsError() throws {
        // ZERO projects — `selectedProject` falls back to `state.projects.first`, and
        // `load()` bootstraps a default project even from an empty seed, so clear
        // projects directly to hit the no-project guard.
        let m = try makeVM(withProject: false)
        m.state.projects = []
        m.selectedProjectID = nil
        m.presentSaveWorkspacePanel()
        XCTAssertEqual(m.errorMessage, WorkbenchSurfacePolicy.noWorkspaceSelectedToSaveMessage,
                       "no selected workspace → the no-workspace error")
    }

    func testPresentSaveWorkspacePanel_noTerminals_setsError() throws {
        let m = try makeVM()  // project, but no entries
        m.presentSaveWorkspacePanel()
        XCTAssertEqual(m.errorMessage, "Home has no terminals to save",
                       "a group with no terminals → the no-terminals error")
    }

    // MARK: - flushPendingOutput (the no-pending guard — the markOutput debounce is carved)

    func testFlushPendingOutput_noPending_isNoOp() throws {
        let m = try makeVM(entries: [entry()])
        let before = m.state.processRuns
        m.flushPendingOutput()
        XCTAssertEqual(m.state.processRuns, before, "no pending output → no mutation")
    }

    // MARK: - restoreDetailLayout (via load() at init)

    func testRestoreDetailLayout_persistedSplit_restoresSplit() throws {
        let layout = PaneLayoutState(
            axis: .vertical, secondaryEntryID: Self.entry2Id, activePane: .primary)
        let m = try makeVM(
            entries: [entry(id: Self.entryId, name: "a"), entry(id: Self.entry2Id, name: "b")],
            detailLayout: layout)
        // load() ran restoreDetailLayout with a persisted split → detailSplit is set.
        XCTAssertNotNil(m.detailSplit,
                        "a persisted detailLayout restores a two-pane split at load")
        XCTAssertEqual(m.detailSplit?.secondaryEntryID, Self.entry2Id,
                       "the restored split keeps its secondary entry when that entry still exists")
    }

    func testRestoreDetailLayout_noPersistedSplit_singlePane() throws {
        let m = try makeVM(entries: [entry()])  // detailLayout: nil
        XCTAssertNil(m.detailSplit, "no persisted layout → classic single pane")
        XCTAssertEqual(m.activePaneID, .primary)
    }
}
#endif
