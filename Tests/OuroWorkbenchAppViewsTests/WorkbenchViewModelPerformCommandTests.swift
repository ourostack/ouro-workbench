#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 2 — `WorkbenchViewModel.performCommand(_:)` (`:5816` descriptor overload +
/// `:5870` command-ID overload, ~147 uncovered lines). Pure command-palette dispatch: each arm
/// sets a @Published sheet flag, routes to a model method, or hits a `guard let selectedEntry else
/// { errorMessage }` no-selection arm. Both overloads are already internal, so each arm is directly
/// INVOKE-able + effect-asserted (the flag / errorMessage / model side-effect) + mutation-verified.
///
/// The `Task { … }` arms (bossQuick*/refreshWorkspace/askBoss) route synchronously (the dispatch arm
/// is covered); their inner async work is a separate boundary. Machinery arms reuse the existing
/// closure seams / a registered no-PTY session (#332).
@MainActor
final class WorkbenchViewModelPerformCommandTests: XCTestCase {

    private static let projectId = UUID(uuidString: "C0DDA9D5-0000-0000-0000-0000000000A1")!
    private static let entryId = UUID(uuidString: "C0DDA9D5-0000-0000-0000-0000000000E1")!
    private static let wsId = UUID(uuidString: "C0DDA9D5-0000-0000-0000-0000000000B1")!

    private func makeVM(withEntry: Bool = false, selectEntry: Bool = false) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmcmd-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let entries = withEntry ? [entry()] : []
        var state = WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            bossWatchEnabled: false,
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp/vmcmd")],
            processEntries: entries,
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: entries.map(\.id))])
        if selectEntry { state.selectedEntryId = Self.entryId }
        try WorkbenchStore(paths: paths).save(state)
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        model.launchTerminalSession = { _ in }
        if selectEntry { model.selectedEntryID = Self.entryId }
        return model
    }

    private func entry() -> ProcessEntry {
        ProcessEntry(id: Self.entryId, projectId: Self.projectId, name: "build", kind: .shell,
                     executable: "/bin/zsh", workingDirectory: "/tmp/vmcmd", trust: .trusted)
    }

    private func registerLive(_ m: WorkbenchViewModel) throws {
        let plan = TerminalCommandPlan(entryId: Self.entryId, executable: "/bin/zsh", arguments: [],
                                       workingDirectory: "/tmp/vmcmd", reason: "vmcmd")
        m.activeSessions[Self.entryId] = try TerminalSessionController(
            plan: plan, onStarted: { _ in }, onOutput: {}, onTerminated: { _ in })
    }

    // MARK: - Sheet-flag arms (each sets a distinct @Published flag)

    func testNewSession_presentsSheet() throws {
        let m = try makeVM()
        m.performCommand(.newSession)
        XCTAssertTrue(m.isNewSessionSheetPresented)
    }

    func testOpenSettings_presentsSettings() throws {
        let m = try makeVM(); m.performCommand(.openSettings)
        XCTAssertTrue(m.isSettingsSheetPresented)
    }

    func testOpenAbout_presentsAbout() throws {
        let m = try makeVM(); m.performCommand(.openAbout)
        XCTAssertTrue(m.isAboutSheetPresented)
    }

    func testOpenHarnessStatus_presents() throws {
        let m = try makeVM(); m.performCommand(.openHarnessStatus)
        XCTAssertTrue(m.isHarnessStatusPresented)
    }

    func testOpenDecisionLog_presents() throws {
        let m = try makeVM(); m.performCommand(.openDecisionLog)
        XCTAssertTrue(m.isDecisionLogPresented)
    }

    func testShowKeyboardShortcutHelp_presents() throws {
        let m = try makeVM(); m.performCommand(.showKeyboardShortcutHelp)
        XCTAssertTrue(m.isShortcutHelpPresented)
    }

    func testOpenOnboarding_presents() throws {
        let m = try makeVM(); m.performCommand(.openOnboarding)
        XCTAssertTrue(m.isOnboardingPresented)
    }

    func testInstallOuroAgent_presentsProviderConfig() throws {
        let m = try makeVM(); m.performCommand(.installOuroAgent)
        XCTAssertTrue(m.isProviderConfigPresented)
    }

    // MARK: - Toggle arms

    func testToggleBossWatch_flips() throws {
        let m = try makeVM()
        XCTAssertFalse(m.bossWatchIsEnabled)
        m.performCommand(.toggleBossWatch)
        XCTAssertTrue(m.bossWatchIsEnabled)
        m.performCommand(.toggleBossWatch)   // back off so no loop lingers
        XCTAssertFalse(m.bossWatchIsEnabled)
    }

    func testToggleBossPane_flips() throws {
        let m = try makeVM()
        let before = m.state.bossPaneCollapsed
        m.performCommand(.toggleBossPane)
        XCTAssertNotEqual(m.state.bossPaneCollapsed, before)
    }

    // MARK: - refresh arms (record action log)

    func testRefreshOuroAgents_recordsLog() throws {
        let m = try makeVM()
        let before = m.state.actionLog.count
        m.performCommand(.refreshOuroAgents)
        XCTAssertEqual(m.state.actionLog.first?.action, "refreshOuroAgents")
        XCTAssertGreaterThan(m.state.actionLog.count, before)
    }

    func testRefreshWorkbenchMCP_recordsLog() throws {
        let m = try makeVM()
        m.performCommand(.refreshWorkbenchMCP)
        XCTAssertEqual(m.state.actionLog.first?.action, "refreshWorkbenchMCP")
    }

    // MARK: - selected-session guard arms (no selection → errorMessage)

    func testSelectedSessionCommands_noSelection_setError() throws {
        let noSelCommands: [WorkbenchCommandID] = [
            .launchSelectedSession, .askBossAboutSelectedSession, .focusSelectedSession,
            .redrawSelectedSession, .sendControlCToSelectedSession, .sendEscapeToSelectedSession,
            .sendEOFToSelectedSession, .copySelectedLaunchCommand, .openSelectedWorkingDirectory,
            .revealSelectedTranscript, .stopSelectedSession, .recoverSelectedSession,
        ]
        for cmd in noSelCommands {
            let m = try makeVM()   // no selected entry
            m.performCommand(cmd)
            XCTAssertEqual(m.errorMessage, "No session is selected",
                           "\(cmd) with no selection must set the no-session error")
        }
    }

    // MARK: - selected-session action arms (with a selected, live session)

    func testLaunchSelectedSession_withSelection_launches() throws {
        let m = try makeVM(withEntry: true, selectEntry: true)
        m.performCommand(.launchSelectedSession)
        // launch routes (no error); the launchTerminalSession seam no-ops the spawn.
        XCTAssertNil(m.errorMessage, "launchSelectedSession with a selection does not error")
    }

    func testStopSelectedSession_withLiveSelection_queuesStop() throws {
        let m = try makeVM(withEntry: true, selectEntry: true)
        try registerLive(m)
        // mark waiting so requestStop queues a confirmation (a live process needs confirmation).
        m.state.processEntries[0].attention = .waitingOnHuman
        m.performCommand(.stopSelectedSession)
        // requestStop on a live process → pendingStopSession set (the consequence gate).
        XCTAssertNotNil(m.pendingStopSession ?? m.activeSessions[Self.entryId].map { _ in nil } ?? nil,
                        "stopSelectedSession routes through requestStop")
    }

    func testRedrawSelectedSession_withLiveSelection_recordsLog() throws {
        let m = try makeVM(withEntry: true, selectEntry: true)
        try registerLive(m)
        let before = m.state.actionLog.count
        m.performCommand(.redrawSelectedSession)
        XCTAssertEqual(m.state.actionLog.count, before + 1)
        XCTAssertEqual(m.state.actionLog.first?.action, "redrawTerminal")
    }

    // MARK: - searchTranscripts (expands boss pane + bumps the focus token)

    func testSearchTranscripts_expandsPaneAndBumpsToken() throws {
        let m = try makeVM()
        m.state.bossPaneCollapsed = true
        let token = m.transcriptSearchFocusToken
        m.performCommand(.searchTranscripts)
        XCTAssertFalse(m.state.bossPaneCollapsed, "searchTranscripts expands the boss pane")
        XCTAssertEqual(m.transcriptSearchFocusToken, token + 1, "it bumps the focus token")
    }

    // MARK: - bossCheckIn routes through attemptCheckIn (no-boss → onboarding)

    func testBossCheckIn_noBoss_presentsOnboarding() throws {
        let m = try makeVM()
        m.state.boss = BossAgentSelection(agentName: "")
        m.performCommand(.bossCheckIn)
        XCTAssertTrue(m.isOnboardingPresented, "bossCheckIn with no boss → attemptCheckIn → onboarding")
    }

    // MARK: - descriptor overload: the payload-bearing + default-forwarding arms

    func testDescriptor_useSelectedAgentAsBoss_noAgent_setsError() throws {
        let m = try makeVM()
        m.selectedAgentName = nil
        m.performCommand(WorkbenchCommandDescriptor(id: .useSelectedAgentAsBoss, title: "", detail: "", systemImage: ""))
        XCTAssertEqual(m.errorMessage, "No agent is selected")
    }

    func testDescriptor_openSelectedAgentConfig_noAgent_setsError() throws {
        let m = try makeVM()
        m.selectedAgentName = nil
        m.performCommand(WorkbenchCommandDescriptor(id: .openSelectedAgentConfig, title: "", detail: "", systemImage: "", payload: "ghost-agent"))
        XCTAssertEqual(m.errorMessage, "No agent is selected")
    }

    func testDescriptor_default_forwardsToCommandIDOverload() throws {
        let m = try makeVM()
        // A non-payload command via the descriptor overload falls to `default` → performCommand(id).
        m.performCommand(WorkbenchCommandDescriptor(id: .newSession, title: "", detail: "", systemImage: ""))
        XCTAssertTrue(m.isNewSessionSheetPresented, "default arm forwards to the command-ID overload")
    }

    // MARK: - Negative control (mutation-verified)

    func testNegativeControl_openSettingsActuallySetsTheFlag() throws {
        // openSettings → isSettingsSheetPresented = true. A no-op arm would leave it false → RED.
        let m = try makeVM()
        XCTAssertFalse(m.isSettingsSheetPresented, "precondition")
        m.performCommand(.openSettings)
        XCTAssertTrue(m.isSettingsSheetPresented, "the openSettings arm set the flag")
    }
}
#endif
