#if os(macOS)
import XCTest
import SwiftUI
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// File-private, NON-isolated copy of `WorkbenchViewModel.recentWorkspacePathsDefaultsKey`
/// (which is `@MainActor`-isolated as a member of the `@MainActor` view model). The
/// inherited `nonisolated` `setUp`/`tearDown` need a non-isolated key to snapshot+restore
/// the recents defaults; `testRecentsKeyMatchesProductionConstant` guards it against drift.
private let dispatchTestsRecentsKey = "ouro.workbench.recentWorkspacePaths"

/// Coverage-tightening PR#1 — `dispatchMenuCommand(_:to:toggleSidebar:)`.
///
/// The ~30 menu-dispatch arms used to live inside `WorkbenchRootView.handleMenuCommand`,
/// a `private` method reachable ONLY via `.onReceive` of the menu-command publisher behind
/// the non-executable `@StateObject` `Scene` root — ViewInspector 0.10.3 has NO driver for
/// that path, so the whole switch was an allowlist carve (residual-baseline.md K1 #1,
/// "borderline carve" flagged by the independent review).
///
/// Extracting the switch into the free `dispatchMenuCommand(_:to:toggleSidebar:)` (the
/// K4-helper pattern, prod byte-identical — `handleMenuCommand` now just forwards here)
/// makes every arm directly INVOKE-able. Each test below: INVOKES the arm, ASSERTS the
/// model side-effect (the @Published flag / method-call effect the arm routes to), and is
/// mutation-verifiable — repointing any arm at a different method flips its assertion RED.
///
/// The one view-local arm — `.toggleSidebar` (which mutates the root's `@State
/// columnVisibility`) — is threaded back through the `toggleSidebar` closure; the test
/// asserts the closure fires (and that NO model state moved).
@MainActor
final class DispatchMenuCommandTests: XCTestCase {

    private static let projectId = UUID(uuidString: "C0FFEE01-0000-0000-0000-0000000000A1")!
    private static let altProjectId = UUID(uuidString: "C0FFEE01-0000-0000-0000-0000000000A2")!
    private static let entry1 = UUID(uuidString: "C0FFEE01-0000-0000-0000-0000000000E1")!
    private static let entry2 = UUID(uuidString: "C0FFEE01-0000-0000-0000-0000000000E2")!
    private static let wsId = UUID(uuidString: "C0FFEE01-0000-0000-0000-0000000000B1")!

    // MARK: - UserDefaults isolation
    //
    // The workspace-open/save flows persist the recent-workspaces list into the SHARED
    // `UserDefaults.standard` (the `recentWorkspacePaths` key), which HeaderView's "Open
    // Recent Workspace" submenu reads back. If a test here leaked a temp path into that key,
    // it would contaminate OTHER suites' committed snapshots (e.g. HeaderCollapsedInboxBadge).
    // Snapshot + restore the key around every test so this suite leaves NO global trace.
    //
    // `setUp`/`tearDown` are inherited `nonisolated`, so they touch only non-isolated state:
    // the file-private `dispatchTestsRecentsKey` constant (the value of the `@MainActor`
    // `WorkbenchViewModel` defaults key, asserted equal below) and a `nonisolated(unsafe)`
    // snapshot box (tests run serially, so the single-threaded access is safe).
    nonisolated(unsafe) private var savedRecents: Any?

    override func setUp() {
        super.setUp()
        savedRecents = UserDefaults.standard.object(forKey: dispatchTestsRecentsKey)
    }

    override func tearDown() {
        if let savedRecents {
            UserDefaults.standard.set(savedRecents, forKey: dispatchTestsRecentsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: dispatchTestsRecentsKey)
        }
        super.tearDown()
    }

    /// Guard the file-private key copy against drift from the production constant.
    func testRecentsKeyMatchesProductionConstant() {
        XCTAssertEqual(dispatchTestsRecentsKey, WorkbenchViewModel.recentWorkspacePathsDefaultsKey,
                       "the isolation key must track the production defaults key")
    }

    // MARK: - Fixtures

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dispatch-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state())
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        // No-op the subprocess-spawning boundary so any arm whose effect touches a
        // session launch never forks a real `screen` child past teardown (#332).
        model.launchTerminalSession = { _ in }
        return model
    }

    private func entry(id: UUID, name: String) -> ProcessEntry {
        ProcessEntry(
            id: id, projectId: Self.projectId, name: name, kind: .shell,
            executable: "/bin/zsh", workingDirectory: "/tmp/dispatch")
    }

    /// Two projects + two session entries in one workspace, so every gated arm
    /// (`.selectTerminal`, `.prevTerminal`, `.splitRight`, `.renameWorkspace`, …)
    /// has a real anchor to take its success path.
    private func state() -> WorkspaceState {
        let e1 = entry(id: Self.entry1, name: "alpha")
        let e2 = entry(id: Self.entry2, name: "beta")
        return WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: [
                WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp/dispatch"),
                WorkbenchProject(id: Self.altProjectId, name: "Other", rootPath: "/tmp/dispatch-2"),
            ],
            processEntries: [e1, e2],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: [Self.entry1, Self.entry2])])
    }

    /// An (un-started, no-PTY) live-session controller registered in `activeSessions`
    /// so arms guarded on a live session (`.redraw`, `.stopSelected`, `.findInTerminal`,
    /// `.toggleFocus`) take their success path.
    private func registerLiveSession(_ model: WorkbenchViewModel, id: UUID) throws {
        let plan = TerminalCommandPlan(
            entryId: id, executable: "/bin/zsh", arguments: [],
            workingDirectory: "/tmp/dispatch", reason: "test dispatch session")
        model.activeSessions[id] = try TerminalSessionController(
            plan: plan, onStarted: { _ in }, onOutput: {}, onTerminated: { _ in })
    }

    /// Forward a command through the production dispatch with a no-op sidebar toggle.
    private func dispatch(_ command: WorkbenchMenuCommand, to model: WorkbenchViewModel) {
        dispatchMenuCommand(command, to: model, toggleSidebar: {})
    }

    // MARK: - Sheet-presenting arms (each sets a distinct @Published flag)

    func testCommandPalette_presentsPalette() throws {
        let m = try makeVM()
        XCTAssertFalse(m.isCommandPalettePresented)
        dispatch(.commandPalette, to: m)
        XCTAssertTrue(m.isCommandPalettePresented, ".commandPalette → isCommandPalettePresented")
    }

    func testNewTerminal_presentsNewSessionSheet() throws {
        let m = try makeVM()
        XCTAssertFalse(m.isNewSessionSheetPresented)
        dispatch(.newTerminal, to: m)
        XCTAssertTrue(m.isNewSessionSheetPresented, ".newTerminal → isNewSessionSheetPresented")
    }

    func testNewTerminalTab_presentsNewSessionSheet() throws {
        let m = try makeVM()
        XCTAssertFalse(m.isNewSessionSheetPresented)
        dispatch(.newTerminalTab, to: m)
        XCTAssertTrue(m.isNewSessionSheetPresented, ".newTerminalTab → isNewSessionSheetPresented")
    }

    func testSettings_presentsSettings() throws {
        let m = try makeVM()
        XCTAssertFalse(m.isSettingsSheetPresented)
        dispatch(.settings, to: m)
        XCTAssertTrue(m.isSettingsSheetPresented, ".settings → isSettingsSheetPresented")
    }

    func testShortcutsHelp_presentsShortcutHelp() throws {
        let m = try makeVM()
        XCTAssertFalse(m.isShortcutHelpPresented)
        dispatch(.shortcutsHelp, to: m)
        XCTAssertTrue(m.isShortcutHelpPresented, ".shortcutsHelp → isShortcutHelpPresented")
    }

    func testAbout_presentsAbout() throws {
        let m = try makeVM()
        XCTAssertFalse(m.isAboutSheetPresented)
        dispatch(.about, to: m)
        XCTAssertTrue(m.isAboutSheetPresented, ".about → isAboutSheetPresented")
    }

    func testReportBug_presentsReportBug() throws {
        let m = try makeVM()
        XCTAssertFalse(m.isReportBugPresented)
        dispatch(.reportBug, to: m)
        XCTAssertTrue(m.isReportBugPresented, ".reportBug → isReportBugPresented")
    }

    // MARK: - Boss / attention arms

    func testBossCheckIn_withUnreachableBoss_presentsHarnessStatus() throws {
        let m = try makeVM()
        // The saved state has boss "boss" but no live/usable agent → checkInAvailability
        // resolves to .bossUnreachable, whose attemptCheckIn arm presents Harness Status
        // (the honest reconnect/repair affordance). Proves the arm routes into attemptCheckIn.
        guard case .bossUnreachable = m.checkInAvailability else {
            return XCTFail("precondition: boss set but unreachable; got \(m.checkInAvailability)")
        }
        XCTAssertFalse(m.isHarnessStatusPresented)
        dispatch(.bossCheckIn, to: m)
        XCTAssertTrue(m.isHarnessStatusPresented, ".bossCheckIn → attemptCheckIn → presents Harness Status")
    }

    func testBossCheckIn_withNoBoss_presentsOnboarding() throws {
        let m = try makeVM()
        // With NO boss configured, checkInAvailability resolves to .noBoss → the
        // attemptCheckIn arm presents onboarding (the other reachable attemptCheckIn arm).
        m.state.boss = BossAgentSelection(agentName: "")
        XCTAssertEqual(m.checkInAvailability, .noBoss, "precondition: no boss configured")
        XCTAssertFalse(m.isOnboardingPresented)
        dispatch(.bossCheckIn, to: m)
        XCTAssertTrue(m.isOnboardingPresented, ".bossCheckIn → attemptCheckIn → presentOnboarding")
    }

    func testJumpToAttention_emptyQueue_setsTransientMessage() throws {
        let m = try makeVM()
        XCTAssertNil(m.errorMessage)
        // No attention-needing session → jumpToNextAttentionSession() returns false →
        // the arm surfaces the inbox-zero transient message (the `if !` TRUE arm).
        dispatch(.jumpToAttention, to: m)
        XCTAssertEqual(m.errorMessage, "Nothing needs you right now.",
                       ".jumpToAttention with empty queue → transient message")
    }

    func testJumpToAttention_withWaitingSession_jumps_noMessage() throws {
        let m = try makeVM()
        // A session that needs the human → jumpToNextAttentionSession() returns true,
        // so the `if !` FALSE arm is taken: the selection moves and NO message is set.
        var e = entry(id: Self.entry1, name: "alpha")
        e.attention = .waitingOnHuman
        m.state.processEntries = [e, entry(id: Self.entry2, name: "beta")]
        m.selectedEntryID = nil
        dispatch(.jumpToAttention, to: m)
        XCTAssertEqual(m.selectedEntryID, Self.entry1, ".jumpToAttention → jumps to the waiting session")
        XCTAssertNil(m.errorMessage, ".jumpToAttention success arm → no transient message")
    }

    // MARK: - Workspace panel arms (driven through the injected NSOpenPanel/NSSavePanel seam)

    func testOpenWorkspace_drivesOpenWorkspaceConfig() throws {
        let m = try makeVM()
        // Stub the modal: return a directory with NO .workbench.json so the value-flow
        // (openWorkspaceConfig(at:)) runs deterministically to its "missing config"
        // message — proving the arm routed into openWorkspaceConfig (not the modal).
        let missingDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dispatch-open-\(UUID().uuidString)", isDirectory: true)
        m.chooseWorkspaceOpenURL = { _ in missingDir }
        XCTAssertNil(m.errorMessage)
        dispatch(.openWorkspace, to: m)
        // openWorkspaceConfig(at:) looks for the canonical .workbench.json inside the
        // chosen directory; with none present it sets the "missing config" message —
        // proving the arm routed into the value-flow (not the modal).
        XCTAssertEqual(m.errorMessage, "No .workbench.json found at \(missingDir.appendingPathComponent(".workbench.json").path)",
                       ".openWorkspace → presentOpenWorkspacePanel → openWorkspaceConfig(at:)")
    }

    func testOpenWorkspace_cancelArm_isNoOp() throws {
        let m = try makeVM()
        m.chooseWorkspaceOpenURL = { _ in nil }   // operator cancelled the modal
        dispatch(.openWorkspace, to: m)
        XCTAssertNil(m.errorMessage, ".openWorkspace cancel arm → no value-flow, no error")
    }

    func testSaveWorkspace_routesIntoSaveWorkspacePanel() throws {
        let m = try makeVM()
        // Drive the `.saveWorkspace` arm into presentSaveWorkspacePanel. We inject a save
        // seam that RECORDS it was invoked and returns nil (the cancel arm), so the method
        // reaches the modal-resolution step (proving the route) but takes its early-return —
        // it does NOT write a recent-workspace (which would pollute the shared UserDefaults
        // recents key that HeaderView's "Open Recent" submenu reads, breaking other suites'
        // snapshots). The Home project has terminals, so we pass the pre-modal guards.
        var sawSavePanel = false
        m.chooseWorkspaceSaveURL = { _ in sawSavePanel = true; return nil }
        dispatch(.saveWorkspace, to: m)
        XCTAssertTrue(sawSavePanel, ".saveWorkspace → presentSaveWorkspacePanel reaches the save-panel seam")
    }

    func testSaveWorkspace_noTerminals_setsMessage_beforeModal() throws {
        let m = try makeVM()
        // Clear the workspace's terminals so the pre-modal `guard !config.terminals.isEmpty`
        // fails: the arm still routes into presentSaveWorkspacePanel (proving the route via
        // the error message) but returns before the modal seam — a strong, write-free assert.
        m.state.processEntries = []
        var sawSavePanel = false
        m.chooseWorkspaceSaveURL = { _ in sawSavePanel = true; return nil }
        dispatch(.saveWorkspace, to: m)
        XCTAssertFalse(sawSavePanel, "no-terminals guard returns before the modal seam")
        XCTAssertEqual(m.errorMessage, "Home has no terminals to save",
                       ".saveWorkspace → presentSaveWorkspacePanel no-terminals message")
    }

    // MARK: - Font arms

    func testFontIncrease_bumpsUp() throws {
        let m = try makeVM()
        let before = m.terminalFontSize
        dispatch(.fontIncrease, to: m)
        XCTAssertEqual(m.terminalFontSize, before + 1, ".fontIncrease → +1")
    }

    func testFontDecrease_bumpsDown() throws {
        let m = try makeVM()
        let before = m.terminalFontSize
        dispatch(.fontDecrease, to: m)
        XCTAssertEqual(m.terminalFontSize, before - 1, ".fontDecrease → -1")
    }

    func testFontReset_resetsToDefault() throws {
        let m = try makeVM()
        m.bumpTerminalFontSize(by: 5)
        XCTAssertNotEqual(m.terminalFontSize, WorkbenchViewModel.defaultTerminalFontSize)
        dispatch(.fontReset, to: m)
        XCTAssertEqual(m.terminalFontSize, WorkbenchViewModel.defaultTerminalFontSize, ".fontReset → default")
    }

    // MARK: - Navigation arms (cycle / select)

    func testSelectTerminal_selectsNthEntry() throws {
        let m = try makeVM()
        m.selectedEntryID = nil
        dispatch(.selectTerminal(2), to: m)
        XCTAssertEqual(m.selectedEntryID, Self.entry2, ".selectTerminal(2) → selects the 2nd entry")
    }

    func testPrevTerminal_cyclesSelection() throws {
        let m = try makeVM()
        m.selectedEntryID = Self.entry2
        dispatch(.prevTerminal, to: m)
        XCTAssertEqual(m.selectedEntryID, Self.entry1, ".prevTerminal → cycles to the previous entry")
    }

    func testNextTerminal_cyclesSelection() throws {
        let m = try makeVM()
        m.selectedEntryID = Self.entry1
        dispatch(.nextTerminal, to: m)
        XCTAssertEqual(m.selectedEntryID, Self.entry2, ".nextTerminal → cycles to the next entry")
    }

    func testPrevGroup_cyclesProject() throws {
        let m = try makeVM()
        m.selectedProjectID = Self.altProjectId
        dispatch(.prevGroup, to: m)
        XCTAssertEqual(m.selectedProjectID, Self.projectId, ".prevGroup → cycles to the previous project")
    }

    func testNextGroup_cyclesProject() throws {
        let m = try makeVM()
        m.selectedProjectID = Self.projectId
        dispatch(.nextGroup, to: m)
        XCTAssertEqual(m.selectedProjectID, Self.altProjectId, ".nextGroup → cycles to the next project")
    }

    // MARK: - Live-session arms (redraw / stop / find / focus)

    func testRedraw_recordsActionLog() throws {
        let m = try makeVM()
        m.selectedEntryID = Self.entry1
        try registerLiveSession(m, id: Self.entry1)
        let before = m.state.actionLog.count
        dispatch(.redraw, to: m)
        XCTAssertEqual(m.state.actionLog.count, before + 1, ".redraw → redrawTerminal records a log")
        XCTAssertEqual(m.state.actionLog.first?.action, "redrawTerminal")
    }

    func testStopSelected_onWaitingSession_queuesConfirmation() throws {
        let m = try makeVM()
        var e = entry(id: Self.entry1, name: "alpha")
        e.attention = .waitingOnHuman
        m.state.processEntries = [e, entry(id: Self.entry2, name: "beta")]
        m.selectedEntryID = Self.entry1
        try registerLiveSession(m, id: Self.entry1)
        XCTAssertNil(m.pendingStopSession)
        dispatch(.stopSelected, to: m)
        XCTAssertEqual(m.pendingStopSession?.id, Self.entry1,
                       ".stopSelected on a live waiting session → requestStop queues confirmation")
    }

    func testRedraw_noActiveEntry_isNoOp() throws {
        let m = try makeVM()
        m.selectedEntryID = nil   // no active entry → the `if let` FALSE arm
        let before = m.state.actionLog.count
        dispatch(.redraw, to: m)
        XCTAssertEqual(m.state.actionLog.count, before, ".redraw with no active entry → no-op")
    }

    func testStopSelected_noActiveEntry_isNoOp() throws {
        let m = try makeVM()
        m.selectedEntryID = nil   // no active entry → the `if let` FALSE arm
        dispatch(.stopSelected, to: m)
        XCTAssertNil(m.pendingStopSession, ".stopSelected with no active entry → no-op")
    }

    func testFindInTerminal_presentsSearch() throws {
        let m = try makeVM()
        m.selectedEntryID = Self.entry1
        try registerLiveSession(m, id: Self.entry1)
        XCTAssertFalse(m.isTerminalSearchPresented)
        dispatch(.findInTerminal, to: m)
        XCTAssertTrue(m.isTerminalSearchPresented, ".findInTerminal → presentTerminalSearch")
    }

    func testToggleFocus_focusesSelectedSession() throws {
        let m = try makeVM()
        m.selectedEntryID = Self.entry1
        try registerLiveSession(m, id: Self.entry1)
        XCTAssertNil(m.terminalFocusEntryID)
        dispatch(.toggleFocus, to: m)
        XCTAssertEqual(m.terminalFocusEntryID, Self.entry1, ".toggleFocus → focusTerminal sets the focus id")
    }

    // MARK: - Split arms

    func testSplitRight_opensVerticalSplit() throws {
        let m = try makeVM()
        m.selectedEntryID = Self.entry1
        XCTAssertNil(m.detailSplit)
        dispatch(.splitRight, to: m)
        XCTAssertEqual(m.detailSplit?.axis, .vertical, ".splitRight → vertical split")
    }

    func testSplitDown_opensHorizontalSplit() throws {
        let m = try makeVM()
        m.selectedEntryID = Self.entry1
        XCTAssertNil(m.detailSplit)
        dispatch(.splitDown, to: m)
        XCTAssertEqual(m.detailSplit?.axis, .horizontal, ".splitDown → horizontal split")
    }

    func testClosePane_collapsesSplit() throws {
        let m = try makeVM()
        m.selectedEntryID = Self.entry1
        dispatch(.splitRight, to: m)
        XCTAssertNotNil(m.detailSplit, "precondition: split is open")
        dispatch(.closePane, to: m)
        XCTAssertNil(m.detailSplit, ".closePane → collapses the split")
    }

    func testFocusOtherPane_togglesActivePane() throws {
        let m = try makeVM()
        m.selectedEntryID = Self.entry1
        dispatch(.splitRight, to: m)   // activePaneID becomes .primary
        dispatch(.focusOtherPane, to: m)
        XCTAssertEqual(m.activePaneID, .secondary, ".focusOtherPane → toggles to the secondary pane")
    }

    // MARK: - Rename arms

    func testRenameWorkspace_opensInlineEditorOnActiveWorkspace() throws {
        let m = try makeVM()
        XCTAssertNil(m.inlineRename.target, "no rename editor before")
        dispatch(.renameWorkspace, to: m)
        XCTAssertEqual(m.inlineRename.target, .workspace(Self.wsId),
                       ".renameWorkspace → beginRenameActiveWorkspace opens the editor on the active workspace")
    }

    func testRenameTab_opensInlineEditorOnSelectedTab() throws {
        let m = try makeVM()
        m.selectedEntryID = Self.entry1
        XCTAssertNil(m.inlineRename.target)
        dispatch(.renameTab, to: m)
        XCTAssertEqual(m.inlineRename.target, .tab(Self.entry1),
                       ".renameTab → beginRenameSelectedTab opens the editor on the selected tab")
    }

    // MARK: - checkForUpdates arm (spawns the async check)

    func testCheckForUpdates_doesNotMutateSyncStateOrCrash() throws {
        let m = try makeVM()
        // The arm spawns `Task { await checkForUpdatesAndPromptInstall() }`; the dispatch
        // itself returns synchronously. We assert it routes without crashing and without
        // touching any of the sheet flags (i.e. it is NOT mis-wired to another arm).
        XCTAssertFalse(m.isAboutSheetPresented)
        dispatch(.checkForUpdates, to: m)
        XCTAssertFalse(m.isAboutSheetPresented, ".checkForUpdates must not present About")
        XCTAssertFalse(m.isCommandPalettePresented, ".checkForUpdates must not open the palette")
    }

    // MARK: - The one view-local arm: .toggleSidebar fires the closure, touches NO model state

    func testToggleSidebar_firesTheClosure_notModel() throws {
        let m = try makeVM()
        var fired = 0
        dispatchMenuCommand(.toggleSidebar, to: m, toggleSidebar: { fired += 1 })
        XCTAssertEqual(fired, 1, ".toggleSidebar → invokes the threaded sidebar closure exactly once")
        // It must NOT have leaked into any model sheet flag.
        XCTAssertFalse(m.isCommandPalettePresented)
        XCTAssertFalse(m.isSettingsSheetPresented)
        XCTAssertFalse(m.isNewSessionSheetPresented)
    }
}
#endif
