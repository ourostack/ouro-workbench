#if os(macOS)
import XCTest
import AppKit
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// Coverage-tightening (Class 2) — `WorkbenchMenuBarController` (the NSMenu/NSStatusItem
/// AppKit menu-bar controller, residual-baseline.md K1 #1).
///
/// It is an AppKit `NSObject`, not a SwiftUI view, so ViewInspector has no driver — it was
/// carved wholesale. But its LOGIC is plain @MainActor code over the view model: `attach`,
/// `refreshIcon`, `setVisible`, the `menuNeedsUpdate`→`rebuildMenu` menu build, and the
/// `@objc` action methods all read/write asserter-visible state (the attached model's
/// @Published flags, the built `NSMenu`'s items, the `NSStatusItem`'s button). This suite
/// constructs a FRESH controller (the widened `init`, not the shared singleton — so tests
/// stay isolated and never touch the prod menu-bar item), drives every reachable region,
/// and asserts the menu/model/status-item side-effect. Mutation-verified.
///
/// **Irreducibly carved (NOT driven here):**
///   - `quitApp` → `NSApp.terminate(nil)` would kill the test process — un-invokable.
///   - `showWorkbench`'s two `for window in NSApp.windows` loop BODIES — the xctest app has
///     no windows, so the loop bodies never execute (its `NSApp.activate`/`unhide` lines ARE
///     covered, transitively, by the actions that call it).
///   - the `NSStatusBar.system.statusItem(...)` / `NSImage(systemSymbolName:)` construction
///     in `init`/`applyIcon` — AppKit-bound; llvm counts the lines covered (init runs), but
///     the system-symbol image path is environment-dependent.
@MainActor
final class WorkbenchMenuBarControllerTests: XCTestCase {

    // NOTE: UUID strings must be HEX only (0-9 a-f). "MENB…" is not a valid UUID.
    private static let projectId = UUID(uuidString: "BEEF0001-0000-0000-0000-0000000000A1")!
    private static let entry1 = UUID(uuidString: "BEEF0001-0000-0000-0000-0000000000E1")!
    private static let entry2 = UUID(uuidString: "BEEF0001-0000-0000-0000-0000000000E2")!
    private static let wsId = UUID(uuidString: "BEEF0001-0000-0000-0000-0000000000B1")!

    // MARK: - Fixtures

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("menubar-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        model.launchTerminalSession = { _ in }
        return model
    }

    private func entry(id: UUID, name: String) -> ProcessEntry {
        ProcessEntry(
            id: id, projectId: Self.projectId, name: name, kind: .shell,
            executable: "/bin/zsh", workingDirectory: "/tmp/menubar")
    }

    private func baseState(entries: [ProcessEntry] = [], bossWatch: Bool = false) -> WorkspaceState {
        // NB: WorkspaceState.bossWatchEnabled DEFAULTS to true; set it explicitly so the
        // watch-off / watch-on menu arms are deterministic regardless of that default.
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            bossWatchEnabled: bossWatch,
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp/menubar")],
            processEntries: entries,
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: entries.map(\.id))])
    }

    /// A fresh, isolated controller (NOT the shared singleton).
    private func controller() -> WorkbenchMenuBarController {
        WorkbenchMenuBarController()
    }

    /// An (un-started, no-PTY) live-session controller registered in `activeSessions`.
    private func registerLiveSession(_ model: WorkbenchViewModel, id: UUID) throws {
        let plan = TerminalCommandPlan(
            entryId: id, executable: "/bin/zsh", arguments: [],
            workingDirectory: "/tmp/menubar", reason: "test menubar session")
        model.activeSessions[id] = try TerminalSessionController(
            plan: plan, onStarted: { _ in }, onOutput: {}, onTerminated: { _ in })
    }

    /// The titles of the controller's built menu items (post `menuNeedsUpdate`).
    private func menuTitles(_ c: WorkbenchMenuBarController) -> [String] {
        c.menu.items.map(\.title)
    }

    // MARK: - attach + refreshIcon (status-item title reflects active count)

    func testAttach_setsModel_andRefreshesIcon() throws {
        let model = try makeVM(state: baseState())
        let c = controller()
        XCTAssertNil(c.model, "no model before attach")
        c.attach(model: model)
        XCTAssertTrue(c.model === model, "attach sets the model")
    }

    func testRefreshIcon_noModel_clearsTitle() throws {
        let c = controller()   // un-attached
        c.refreshIcon()
        XCTAssertEqual(c.statusItem.button?.title ?? "", "",
                       "no model → neutral icon, no running-count title")
    }

    func testRefreshIcon_noActiveSessions_emptyTitle() throws {
        let model = try makeVM(state: baseState())
        let c = controller()
        c.attach(model: model)   // attach calls refreshIcon
        XCTAssertEqual(c.statusItem.button?.title ?? "", "",
                       "0 active sessions → empty title")
    }

    func testRefreshIcon_withActiveSessions_showsCount() throws {
        let model = try makeVM(state: baseState(entries: [entry(id: Self.entry1, name: "alpha")]))
        try registerLiveSession(model, id: Self.entry1)
        let c = controller()
        c.attach(model: model)
        XCTAssertEqual(c.statusItem.button?.title, " 1",
                       "1 active session → ' 1' title")
        XCTAssertEqual(c.statusItem.button?.toolTip, "Ouro Workbench — 1 running",
                       "the running-count tooltip")
    }

    // MARK: - setVisible

    func testSetVisible_togglesStatusItem() throws {
        let c = controller()
        c.setVisible(false)
        XCTAssertFalse(c.statusItem.isVisible, "setVisible(false) hides the status item")
        c.setVisible(true)
        XCTAssertTrue(c.statusItem.isVisible, "setVisible(true) shows the status item")
    }

    // MARK: - menuNeedsUpdate → rebuildMenu (the ~54-region menu build)

    func testRebuild_noModel_minimalMenu() throws {
        let c = controller()   // un-attached → the `guard let model` FALSE arm
        c.menuNeedsUpdate(c.menu)
        let titles = menuTitles(c)
        XCTAssertEqual(titles.first, "Ouro Workbench", "no-model menu leads with the disabled app name")
        XCTAssertTrue(titles.contains("Quit Ouro Workbench"), "no-model menu still has Quit")
        XCTAssertFalse(titles.contains("Show Workbench"), "no-model menu has no Show Workbench")
    }

    func testRebuild_attached_noSessions_watchOff() throws {
        let model = try makeVM(state: baseState())
        let c = controller()
        c.attach(model: model)
        c.menuNeedsUpdate(c.menu)
        let titles = menuTitles(c)
        XCTAssertTrue(titles.contains("Show Workbench"), "attached menu has Show Workbench")
        XCTAssertTrue(titles.contains("No running sessions"), "no active sessions → the empty row")
        XCTAssertTrue(titles.contains("Start Boss Watch"), "watch off → 'Start Boss Watch'")
        XCTAssertTrue(titles.contains(WorkbenchViewModel.checkInActionLabel), "the Check In item")
        XCTAssertFalse(titles.contains(where: { $0.hasPrefix("Recovery:") }),
                       "no recoverable sessions → no Recovery item")
    }

    func testRebuild_withOneActiveSession_singularHeader_andRow() throws {
        let e = entry(id: Self.entry1, name: "alpha")
        let model = try makeVM(state: baseState(entries: [e]))
        try registerLiveSession(model, id: Self.entry1)
        let c = controller()
        c.attach(model: model)
        c.menuNeedsUpdate(c.menu)
        let titles = menuTitles(c)
        XCTAssertTrue(titles.contains("1 running session"), "singular header (count==1, no 's')")
        XCTAssertTrue(titles.contains("  · alpha"), "the per-session jump row")
        XCTAssertFalse(titles.contains("No running sessions"), "the empty row is absent")
    }

    func testRebuild_withTwoActiveSessions_pluralHeader() throws {
        let e1 = entry(id: Self.entry1, name: "alpha")
        let e2 = entry(id: Self.entry2, name: "beta")
        let model = try makeVM(state: baseState(entries: [e1, e2]))
        try registerLiveSession(model, id: Self.entry1)
        try registerLiveSession(model, id: Self.entry2)
        let c = controller()
        c.attach(model: model)
        c.menuNeedsUpdate(c.menu)
        let titles = menuTitles(c)
        XCTAssertTrue(titles.contains("2 running sessions"), "plural header (count==2, 's')")
        XCTAssertTrue(titles.contains("  · alpha") && titles.contains("  · beta"), "both jump rows")
    }

    func testRebuild_watchOn_showsStopWatch() throws {
        let model = try makeVM(state: baseState(bossWatch: true))   // the watch-on ternary arm
        let c = controller()
        c.attach(model: model)
        c.menuNeedsUpdate(c.menu)
        XCTAssertTrue(menuTitles(c).contains("Stop Boss Watch"), "watch on → 'Stop Boss Watch'")
    }

    /// `recoverable > 0` TRUE arm: a `.needsRecovery` trusted+autoResume run yields an
    /// actionable recovery plan, so the "Recovery: N waiting…" item renders.
    func testRebuild_withRecoverableSessions_showsRecoveryItem() throws {
        var e = entry(id: Self.entry1, name: "respawn-me")
        e.trust = .trusted
        e.autoResume = true
        var bytes = Self.entry1.uuid; bytes.15 ^= 0xFF
        let run = ProcessRun(id: UUID(uuid: bytes), entryId: Self.entry1, status: .needsRecovery,
                             startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        var state = baseState(entries: [e])
        state.processRuns = [run]
        let model = try makeVM(state: state)
        let c = controller()
        c.attach(model: model)
        XCTAssertGreaterThan(model.recoveryDigest.actionableCount, 0,
                             "provenance: a needs-recovery run → an actionable recovery plan")
        c.menuNeedsUpdate(c.menu)
        XCTAssertTrue(menuTitles(c).contains(where: { $0.hasPrefix("Recovery:") }),
                      "recoverable > 0 → the 'Recovery: N waiting…' item renders")
    }

    // MARK: - @objc actions (invoked via Obj-C dispatch; assert the model side-effect)

    private func perform(_ c: WorkbenchMenuBarController, _ selectorName: String, with arg: Any? = nil) {
        let sel = Selector(selectorName)
        XCTAssertTrue(c.responds(to: sel), "controller responds to \(selectorName)")
        if let arg {
            _ = c.perform(sel, with: arg)
        } else {
            _ = c.perform(sel)
        }
    }

    func testAction_jumpToSession_selectsEntry() throws {
        let e = entry(id: Self.entry1, name: "alpha")
        let model = try makeVM(state: baseState(entries: [e]))
        let c = controller()
        c.attach(model: model)
        model.selectedEntryID = nil
        let item = NSMenuItem(title: "  · alpha", action: nil, keyEquivalent: "")
        item.representedObject = Self.entry1.uuidString
        perform(c, "jumpToSession:", with: item)
        XCTAssertEqual(model.selectedEntryID, Self.entry1,
                       "jumpToSession → selectEntryAcrossGroups selects the entry")
    }

    func testAction_jumpToSession_badRepresentedObject_isNoOp() throws {
        let model = try makeVM(state: baseState(entries: [entry(id: Self.entry1, name: "alpha")]))
        let c = controller()
        c.attach(model: model)
        model.selectedEntryID = nil
        let item = NSMenuItem(title: "junk", action: nil, keyEquivalent: "")
        item.representedObject = "not-a-uuid"   // the guard FALSE arm
        perform(c, "jumpToSession:", with: item)
        XCTAssertNil(model.selectedEntryID, "a non-UUID represented object → no selection (guard return)")
    }

    func testAction_openRecoverySheet_presentsSheet() throws {
        let model = try makeVM(state: baseState())
        let c = controller()
        c.attach(model: model)
        XCTAssertFalse(model.isRecoverySheetPresented)
        perform(c, "openRecoverySheet")
        XCTAssertTrue(model.isRecoverySheetPresented, "openRecoverySheet → presents the recovery sheet")
    }

    func testAction_toggleBossWatch_flipsTheFlag() throws {
        // Start ON so the toggle goes ON→OFF (the disable path cancels the loop, no spawn).
        let model = try makeVM(state: baseState(bossWatch: true))
        let c = controller()
        c.attach(model: model)
        XCTAssertTrue(model.bossWatchIsEnabled, "precondition: watch on")
        perform(c, "toggleBossWatch")
        XCTAssertFalse(model.bossWatchIsEnabled, "toggleBossWatch ON→OFF disables watch")
    }

    func testAction_toggleBossWatch_noModel_isNoOp() throws {
        let c = controller()   // un-attached → the guard FALSE arm
        // Must not crash; nothing to assert beyond not trapping.
        perform(c, "toggleBossWatch")
    }

    func testAction_quickAskBoss_withUnreachableBoss_presentsHarnessStatus() throws {
        let model = try makeVM(state: baseState())
        let c = controller()
        c.attach(model: model)
        guard case .bossUnreachable = model.checkInAvailability else {
            return XCTFail("precondition: boss set but unreachable; got \(model.checkInAvailability)")
        }
        XCTAssertFalse(model.isHarnessStatusPresented)
        perform(c, "quickAskBoss")
        XCTAssertTrue(model.isHarnessStatusPresented,
                      "quickAskBoss → attemptCheckIn → presents Harness Status")
    }

    func testAction_quickAskBoss_whileRunning_isNoOp() throws {
        let model = try makeVM(state: baseState())
        model.bossCheckInIsRunning = true   // the guard FALSE arm
        let c = controller()
        c.attach(model: model)
        perform(c, "quickAskBoss")
        XCTAssertFalse(model.isHarnessStatusPresented,
                       "quickAskBoss while a check-in is running → no-op (guard return)")
    }
}
#endif
