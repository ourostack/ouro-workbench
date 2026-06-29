#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 13 — the FINAL mop-up: the last genuinely-drivable pure-logic
/// arms left in the residual before the irreducible machinery floor.
///
/// Drives:
///   • `windowTitle` (`:4300`) — the title-composition computed property. Every
///     focus arm (agent / group+entry / entry-no-group / project / empty) ×
///     every final-format arm (both-empty → appName, focus-empty → "app — boss",
///     full → "app — boss — focus").
///   • `stepTerminalSearch` (`:2623`) — the no-active-session guard (sets
///     `terminalSearchHasResult = false`, returns false) + the empty-query arm
///     (clears search, returns true) + the find-next/find-previous arms (via a
///     registered live `TerminalSessionController`).
///   • `exportWorkspaceConfig` (`:3538`) — the three working-directory arms
///     (== root → nil, under-root → relative, else → absolute) + the group/root
///     projection.
///   • `presentSaveWorkspacePanel` (`:3572`) — the no-project guard, the
///     no-terminals guard, and the write path (the `chooseWorkspaceSaveURL`
///     NSSavePanel seam is injected to return a temp URL so the encode + atomic
///     write + action-log arm runs; only the live `panel.runModal()` is carved).
///   • `markOutput` (`:9495`) + `flushPendingOutput` (`:9513`, widened
///     private→internal) — the coalesced-output record + the flush fold
///     (no-pending guard / per-run `lastOutputAt` mutate / `didMutate` → save).
///   • `restoreDetailLayout` (`:10165`, exercised via `load()` at init) — the
///     persisted-split-present arm (a seeded `state.detailLayout` restores the
///     split), complementing the no-layout arm every other test's init covers.
///
/// CARVED (genuine machinery, NOT driven): `scheduleOutputFlush`'s `Task.sleep`
/// debounce; the live `panel.runModal()` inside the default `chooseWorkspaceSaveURL`;
/// the `session.terminal.findNext/findPrevious` SwiftTerm result is asserted as a
/// Bool (the headless terminal has no buffer, so the hit is false — the value-flow
/// through the production branch is what's covered).
@MainActor
final class WorkbenchViewModelFinalMopupTests: XCTestCase {

    private static let projectId = UUID(uuidString: "C13F1A00-0000-0000-0000-0000000000A1")!
    private static let entryId = UUID(uuidString: "C13F1A00-0000-0000-0000-0000000000E1")!
    private static let entry2Id = UUID(uuidString: "C13F1A00-0000-0000-0000-0000000000E2")!
    private static let wsId = UUID(uuidString: "C13F1A00-0000-0000-0000-0000000000B1")!
    private static let runId = UUID(uuidString: "C13F1A00-0000-0000-0000-0000000000F1")!

    @MainActor private final class SaveURLRecorder { var captured: URL? }

    private func makeVM(
        entries: [ProcessEntry] = [],
        runs: [ProcessRun] = [],
        boss: String = "boss",
        rootPath: String = "/tmp/vmmopup",
        detailLayout: PaneLayoutState? = nil
    ) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmmopup-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: boss),
            bossWatchEnabled: false,
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: rootPath)],
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
        return m
    }

    private func entry(
        id: UUID = entryId, name: String = "build", workingDirectory: String = "/tmp/vmmopup"
    ) -> ProcessEntry {
        ProcessEntry(id: id, projectId: Self.projectId, name: name, kind: .shell,
                     executable: "/bin/zsh", workingDirectory: workingDirectory, trust: .trusted)
    }

    private func registerLive(_ m: WorkbenchViewModel, entryId: UUID = entryId) throws {
        let plan = TerminalCommandPlan(
            entryId: entryId, runId: Self.runId, executable: "/bin/zsh", arguments: [],
            workingDirectory: "/tmp/vmmopup", reason: "mopup test")
        m.activeSessions[entryId] = try TerminalSessionController(
            plan: plan, onStarted: { _ in }, onOutput: {}, onTerminated: { _ in })
    }

    // MARK: - windowTitle

    func testWindowTitle_bossAndProjectFocus() throws {
        let m = try makeVM()
        // No selected entry/agent → focus is the selected project's name.
        XCTAssertEqual(m.windowTitle, "Ouro Workbench — boss — Home",
                       "project focus composes app — boss — group")
    }

    func testWindowTitle_emptyBossAndNoFocus_isAppNameOnly() throws {
        let m = try makeVM(boss: "")
        m.selectedProjectID = nil
        m.selectedEntryID = nil
        m.selectedAgentName = nil
        XCTAssertEqual(m.windowTitle, "Ouro Workbench",
                       "empty boss + empty focus → bare app name")
    }

    func testWindowTitle_bossButNoFocus_isAppDashBoss() throws {
        let m = try makeVM()
        m.selectedProjectID = nil
        m.selectedEntryID = nil
        m.selectedAgentName = nil
        XCTAssertEqual(m.windowTitle, "Ouro Workbench — boss",
                       "boss set + empty focus → app — boss")
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

    // MARK: - stepTerminalSearch

    func testStepTerminalSearch_noActiveSession_returnsFalseAndClearsResult() throws {
        let m = try makeVM(entries: [entry()])
        m.terminalSearchHasResult = true
        let hit = m.stepTerminalSearch(direction: .next)
        XCTAssertFalse(hit, "no active session → no search result")
        XCTAssertFalse(m.terminalSearchHasResult, "the guard arm clears terminalSearchHasResult")
    }

    func testStepTerminalSearch_emptyQuery_clearsSearchAndReportsResult() throws {
        let m = try makeVM(entries: [entry()])
        m.selectedEntryID = Self.entryId
        try registerLive(m)
        m.terminalSearchQuery = ""
        let hit = m.stepTerminalSearch(direction: .next)
        XCTAssertTrue(hit, "an empty query clears the search and reports a (vacuous) result")
        XCTAssertTrue(m.terminalSearchHasResult)
    }

    func testStepTerminalSearch_nonEmptyQuery_runsFindAndRecordsResult() throws {
        let m = try makeVM(entries: [entry()])
        m.selectedEntryID = Self.entryId
        try registerLive(m)
        m.terminalSearchQuery = "needle"
        // The headless terminal has no buffer, so findNext returns false — but the
        // production find-next branch + the terminalSearchHasResult assignment run.
        let hit = m.stepTerminalSearch(direction: .next)
        XCTAssertEqual(m.terminalSearchHasResult, hit, "result mirrors the find outcome")
        let prevHit = m.stepTerminalSearch(direction: .previous)
        XCTAssertEqual(m.terminalSearchHasResult, prevHit, "previous arm also records its outcome")
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

    // MARK: - presentSaveWorkspacePanel

    func testPresentSaveWorkspacePanel_noProject_setsError() throws {
        let m = try makeVM(entries: [entry()])
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

    func testPresentSaveWorkspacePanel_writesConfigViaSeam() throws {
        let m = try makeVM(entries: [entry()])
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmmopup-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let target = out.appendingPathComponent(WorkbenchWorkspaceConfigLoader.configFileName)
        m.chooseWorkspaceSaveURL = { _ in target }
        m.presentSaveWorkspacePanel()
        XCTAssertNil(m.errorMessage, "a successful write surfaces no error")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path),
                      "the workspace config is written to the seam-provided URL")
        let decoded = try JSONDecoder().decode(
            WorkbenchWorkspaceConfig.self, from: Data(contentsOf: target))
        XCTAssertEqual(decoded.group, "Home")
        XCTAssertEqual(decoded.terminals.count, 1)
    }

    func testPresentSaveWorkspacePanel_cancelledSeam_isNoOp() throws {
        let m = try makeVM(entries: [entry()])
        m.chooseWorkspaceSaveURL = { _ in nil }  // operator cancelled the panel
        m.presentSaveWorkspacePanel()
        XCTAssertNil(m.errorMessage, "cancelling the save panel is a clean no-op")
    }

    // MARK: - markOutput + flushPendingOutput

    func testFlushPendingOutput_noPending_isNoOp() throws {
        let m = try makeVM(entries: [entry()])
        let before = m.state.processRuns
        m.flushPendingOutput()
        XCTAssertEqual(m.state.processRuns, before, "no pending output → no mutation")
    }

    func testMarkOutputThenFlush_stampsLastOutputAt() throws {
        let run = ProcessRun(
            id: Self.runId, entryId: Self.entryId, status: .running,
            startedAt: Date(timeIntervalSince1970: 1_000))
        let m = try makeVM(entries: [entry()], runs: [run])
        XCTAssertNil(m.state.processRuns.first { $0.id == Self.runId }?.lastOutputAt)
        m.markOutput(entryId: Self.entryId, runId: Self.runId)
        m.flushPendingOutput()
        XCTAssertNotNil(m.state.processRuns.first { $0.id == Self.runId }?.lastOutputAt,
                        "the flush fold stamps lastOutputAt on the matching run")
        // Idempotent: a second flush with the queue now drained is a clean no-op.
        let after = m.state.processRuns
        m.flushPendingOutput()
        XCTAssertEqual(m.state.processRuns, after, "the drained queue flushes to a no-op")
    }

    func testMarkOutput_unknownRun_flushesWithoutMutating() throws {
        let m = try makeVM(entries: [entry()])  // no processRuns
        m.markOutput(entryId: Self.entryId, runId: Self.runId)
        let before = m.state.processRuns
        m.flushPendingOutput()
        XCTAssertEqual(m.state.processRuns, before,
                       "a pending stamp for a run not in processRuns drains without mutating state")
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
