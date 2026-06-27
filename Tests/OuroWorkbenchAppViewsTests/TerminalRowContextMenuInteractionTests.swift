#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B1 — `TerminalRowContextMenu` (`:3615`) action-closure INTERACTION drive-to-100%.
///
/// The C0 `TerminalRowContextMenuStandaloneTests` snapshot every menu LABEL (Launch/Restart,
/// Stop, Pin, Edit/Duplicate/Move/Archive/Restore/Delete) but never EXECUTE a single button
/// action, so all 16 of this decl's action-closure regions (`Button { … }` bodies + the
/// `isPinned` label ternary's pinned arm + the Move-to-Workspace per-project `Button`) were
/// uncovered. This suite FINDS each menu button via `find(button:)` and `.tap()`s it →
/// executing the actuator AND asserting its `@Published`/`state` side-effect, then
/// MUTATION-VERIFIES the load-bearing ones (see the negative-control tests).
///
/// ViewInspector 0.10.3 descends `Menu { }` content AND invokes `Button` actions via `.tap()`,
/// so the "Move to Workspace" sub-`Menu`'s per-project `Button(project.name)` is reachable too.
///
/// **Provenance (P2).** `entry` + `model` are provenance-built via the REAL store seam
/// (`WorkbenchStore(paths:).save(state)` → a fresh `WorkbenchViewModel` whose `load()` reads +
/// migrates the persisted state; AN-001 dual-injection keeps the inventory scan hermetic). Each
/// actuator's availability is driven by REAL state (a custom `.shell` session, a pinned entry, a
/// two-project state for Move, an archived entry for Restore). The menu's `entry` is re-read off
/// the loaded model so it is the migrated value, never hand-assembled.
///
/// **Determinism (P3).** Fixed entry/workspace/project ids + a FIXED `/tmp/u5b1` working
/// directory; no clock; `!contains("/Users/")`.
///
/// **Carve:** none — every reachable action is driven. (The "Launch" action's non-archived arm
/// schedules a `Task { await start(...) }`; tapping executes the synchronous closure region. The
/// async `start` is the live-PTY path covered/charged on the non-gated VM file, not here.)
@MainActor
final class TerminalRowContextMenuInteractionTests: XCTestCase {

    private static let projectA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private static let projectB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    private static let tabId = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
    private static let wsId = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b1-trcm-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
        // #332 seam: tapping "Launch" drives `launch(entry)` -> the detached
        // `Task { await start(entry:with:) }` -> `session.start()`, which forks a real `screen`
        // child that outlives the test and orphans past teardown (CI signal-1 crash). Inject a
        // no-op launcher so the session is still constructed + stored in `activeSessions` (kept
        // for the live-session provenance other tests in this suite assert) but NO subprocess
        // is spawned.
        model.launchTerminalSession = { _ in }
        return model
    }

    private func entry(
        kind: ProcessKind = .shell,
        isArchived: Bool = false,
        isPinned: Bool = false,
        attention: AttentionState = .idle,
        projectId: UUID = TerminalRowContextMenuInteractionTests.projectA
    ) -> ProcessEntry {
        ProcessEntry(
            id: Self.tabId, projectId: projectId, name: "build", kind: kind,
            executable: "/bin/zsh", workingDirectory: "/tmp/u5b1",
            isArchived: isArchived, isPinned: isPinned, attention: attention
        )
    }

    /// A single-project state (Move-to-Workspace not reachable: `projects.count < 2`).
    private func state(entry: ProcessEntry) -> WorkspaceState {
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: [WorkbenchProject(id: Self.projectA, name: "Frontend", rootPath: "/tmp/u5b1")],
            processEntries: [entry],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: entry.isArchived ? [] : [Self.tabId])]
        )
    }

    /// A two-project state so the Move-to-Workspace `Menu`'s per-project `Button` is enabled
    /// (`projects.count >= 2`) and a target project distinct from the entry's projectId exists.
    private func twoProjectState(entry: ProcessEntry) -> WorkspaceState {
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: [
                WorkbenchProject(id: Self.projectA, name: "Frontend", rootPath: "/tmp/u5b1"),
                WorkbenchProject(id: Self.projectB, name: "Backend", rootPath: "/tmp/u5b1b")
            ],
            processEntries: [entry],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: [Self.tabId])]
        )
    }

    private func menu(for entry: ProcessEntry, model: WorkbenchViewModel) -> TerminalRowContextMenu {
        let loaded = model.state.processEntries.first ?? entry
        return TerminalRowContextMenu(entry: loaded, model: model)
    }

    /// Inject a real `TerminalSessionController` (from a real `TerminalCommandPlan`, NO `start()`
    /// → no process spawns) into the published `activeSessions` map the live launch path also
    /// writes, so `activeSession(for:) != nil` and the menu's Stop arm renders + is tappable.
    private func modelWithActiveSession(for entry: ProcessEntry) throws -> (WorkbenchViewModel, ProcessEntry) {
        let model = try makeVM(state: state(entry: entry))
        let loaded = model.state.processEntries.first ?? entry
        let plan = TerminalCommandPlan(
            entryId: loaded.id, executable: "/bin/zsh", arguments: [],
            workingDirectory: "/tmp/u5b1", reason: "test active session")
        let controller = try TerminalSessionController(
            plan: plan, onStarted: { _ in }, onOutput: {}, onTerminated: { _ in })
        model.activeSessions[loaded.id] = controller
        return (model, loaded)
    }

    // MARK: - Stop (the destructive action arm — needs a live session)

    func testTap_stop_liveSession_armsConfirmation() throws {
        // The Stop button renders only when `activeSession(for:) != nil`. An `.active` live agent
        // holds context, so `WorkbenchSurfacePolicy.stopNeedsConfirmation` is true → requestStop
        // arms `pendingStopSession` (the U11 consequence-gated path) — a clean observable effect.
        let (model, loaded) = try modelWithActiveSession(for: entry(attention: .active))
        let view = TerminalRowContextMenu(entry: loaded, model: model)
        XCTAssertNotNil(model.activeSession(for: loaded), "provenance: a live session → the Stop arm")
        XCTAssertNil(model.pendingStopSession, "provenance: nothing pending stop yet")
        try view.inspect().find(button: "Stop").tap()
        XCTAssertEqual(model.pendingStopSession?.id, loaded.id,
                       "Stop on a live agent arms the stop confirmation (requestStop)")
    }

    // MARK: - Launch (the inactive → "Launch" arm, action closure)

    func testTap_launch_inactiveCustom_executesLaunch() throws {
        // A non-archived custom shell: "Launch" is enabled. Tapping invokes model.launch(entry),
        // whose synchronous region builds a plan + schedules the live-start Task (the async start
        // is charged on the non-gated VM file). No errorMessage means the plan built cleanly.
        let model = try makeVM(state: state(entry: entry()))
        let view = menu(for: entry(), model: model)
        XCTAssertNil(model.activeSession(for: view.entry), "provenance: no live session → Launch")
        try view.inspect().find(button: "Launch").tap()
        XCTAssertNil(model.errorMessage, "Launch built a plan cleanly (no error):\(model.errorMessage ?? "")")
    }

    // MARK: - Ask Boss About This Session (Task wrapper)

    func testTap_askBoss_setsBossQuestionAndExpandsPane() async throws {
        let model = try makeVM(state: state(entry: entry()))
        model.setBossPaneCollapsed(true)
        let view = menu(for: entry(), model: model)
        try view.inspect().find(button: "Ask Boss About This Session").tap()
        // The button body is `Task { await model.runBossQuestion(about: entry) }`; the Task's
        // FIRST synchronous lines (before any await) set bossQuestion + expand the pane.
        for _ in 0..<500 where model.bossQuestion.isEmpty { await Task.yield() }
        XCTAssertEqual(model.bossQuestion, "What is going on with build?", "ask-boss set the short question")
        XCTAssertFalse(model.state.bossPaneCollapsed, "ask-boss expanded the boss pane")
    }

    // MARK: - Pin / Unpin (action + the isPinned label ternary)

    func testTap_pin_unpinnedEntry_pinsIt() throws {
        let model = try makeVM(state: state(entry: entry(isPinned: false)))
        let view = menu(for: entry(isPinned: false), model: model)
        XCTAssertFalse(model.isPinned(view.entry), "provenance: starts unpinned → 'Pin to Top'")
        try view.inspect().find(button: "Pin to Top").tap()
        XCTAssertTrue(model.isPinned(view.entry), "Pin to Top pins the entry")
    }

    func testTap_unpin_pinnedEntry_unpinsIt_andRendersUnpinLabel() throws {
        // A PINNED entry renders the "Unpin from Top" / "pin.slash" arm of the isPinned ternary.
        let model = try makeVM(state: state(entry: entry(isPinned: true)))
        let view = menu(for: entry(isPinned: true), model: model)
        XCTAssertTrue(model.isPinned(view.entry), "provenance: starts pinned → 'Unpin from Top'")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("Unpin from Top"), "pinned: the Unpin label (ternary arm):\n\(tree)")
        XCTAssertTrue(tree.contains("pin.slash"), "pinned: the pin.slash glyph (ternary arm):\n\(tree)")
        try view.inspect().find(button: "Unpin from Top").tap()
        XCTAssertFalse(model.isPinned(view.entry), "Unpin from Top unpins the entry")
    }

    // MARK: - Copy Launch Command / Copy Last 20 Lines

    func testTap_copyLaunchCommand_recordsActionLog() throws {
        let model = try makeVM(state: state(entry: entry()))
        let view = menu(for: entry(), model: model)
        let before = model.state.actionLog.count
        try view.inspect().find(button: "Copy Launch Command").tap()
        XCTAssertEqual(model.state.actionLog.count, before + 1, "copyLaunchCommand records an action-log entry")
        XCTAssertEqual(model.state.actionLog.first?.action, "copyLaunchCommand", "the recorded action is copyLaunchCommand")
    }

    func testTap_copyTranscriptTail_withTranscript_recordsActionLog() throws {
        // The "Copy Last 20 Lines" button is `.disabled(latestRun?.transcriptPath == nil)`, so its
        // action region is only reachable when a transcript exists on disk (the disabled no-transcript
        // arm a tap can never reach). We write a real transcript file + a ProcessRun pointing at it, so
        // the ENABLED button taps through to copyTranscriptTail's success path (the action region).
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b1-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let transcript = tmp.appendingPathComponent("build.log")
        try "line one\nline two\nline three\n".write(to: transcript, atomically: true, encoding: .utf8)
        let run = ProcessRun(
            id: UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000001")!,
            entryId: Self.tabId, status: .exited,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            transcriptPath: transcript.path)
        var st = state(entry: entry())
        st.processRuns = [run]
        let model = try makeVM(state: st)
        let view = menu(for: entry(), model: model)
        XCTAssertNotNil(model.latestRun(for: view.entry)?.transcriptPath, "provenance: a transcript on disk")
        let before = model.state.actionLog.count
        try view.inspect().find(button: "Copy Last 20 Lines").tap()
        XCTAssertEqual(model.state.actionLog.first?.action, "copyTranscriptTail",
                       "copyTranscriptTail recorded its action-log entry (success path)")
        XCTAssertEqual(model.state.actionLog.count, before + 1, "exactly one entry recorded")
    }

    // MARK: - Open Working Directory (missing-dir guard arm)

    func testTap_openWorkingDirectory_missingDir_setsErrorMessage() throws {
        // /tmp/u5b1 does not exist on disk → the missing-directory guard arm sets errorMessage.
        let model = try makeVM(state: state(entry: entry()))
        let view = menu(for: entry(), model: model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/u5b1"), "provenance: dir absent")
        try view.inspect().find(button: "Open Working Directory").tap()
        XCTAssertEqual(model.errorMessage, "Working directory does not exist: /tmp/u5b1",
                       "missing-directory guard fires")
    }

    // MARK: - Edit Session… / Duplicate Session

    func testTap_editSession_setsEditingSession() throws {
        let model = try makeVM(state: state(entry: entry()))
        let view = menu(for: entry(), model: model)
        XCTAssertNil(model.editingSession, "provenance: not editing yet")
        try view.inspect().find(button: "Edit Session…").tap()
        XCTAssertEqual(model.editingSession?.id, Self.tabId, "Edit Session… begins editing this entry")
    }

    func testTap_duplicateSession_appendsACopy() throws {
        let model = try makeVM(state: state(entry: entry()))
        let view = menu(for: entry(), model: model)
        let before = model.state.processEntries.count
        try view.inspect().find(button: "Duplicate Session").tap()
        XCTAssertEqual(model.state.processEntries.count, before + 1, "Duplicate Session appends a copy")
    }

    // MARK: - Move to Workspace (the per-project Button inside the descended Menu)

    func testTap_moveToWorkspace_movesEntryToTargetProject() throws {
        let model = try makeVM(state: twoProjectState(entry: entry(projectId: Self.projectA)))
        let view = menu(for: entry(projectId: Self.projectA), model: model)
        XCTAssertEqual(model.state.processEntries.first?.projectId, Self.projectA, "provenance: in project A")
        // The "Backend" target Button (distinct from the entry's project → enabled) inside the
        // descended Move-to-Workspace Menu.
        try view.inspect().find(button: "Backend").tap()
        XCTAssertEqual(model.state.processEntries.first?.projectId, Self.projectB,
                       "Move to Workspace moves the entry to the target project")
    }

    // MARK: - Archive / Restore

    func testTap_archiveSession_archivesEntry() throws {
        let model = try makeVM(state: state(entry: entry(isArchived: false)))
        let view = menu(for: entry(isArchived: false), model: model)
        XCTAssertFalse(model.state.processEntries.first?.isArchived ?? true, "provenance: not archived")
        try view.inspect().find(button: "Archive Session").tap()
        XCTAssertTrue(model.state.processEntries.first?.isArchived ?? false, "Archive Session archives the entry")
    }

    func testTap_restoreSession_restoresEntry() throws {
        let model = try makeVM(state: state(entry: entry(isArchived: true)))
        let view = menu(for: entry(isArchived: true), model: model)
        XCTAssertTrue(model.state.processEntries.first?.isArchived ?? false, "provenance: archived → Restore arm")
        try view.inspect().find(button: "Restore").tap()
        XCTAssertFalse(model.state.processEntries.first?.isArchived ?? true, "Restore un-archives the entry")
    }

    // MARK: - Delete Session… (the destructive Button → pendingDeleteSession)

    func testTap_deleteSession_armsPendingDelete() throws {
        let model = try makeVM(state: state(entry: entry()))
        let view = menu(for: entry(), model: model)
        XCTAssertNil(model.pendingDeleteSession, "provenance: nothing pending delete")
        try view.inspect().find(button: "Delete Session…").tap()
        XCTAssertEqual(model.pendingDeleteSession?.id, Self.tabId, "Delete Session… arms the confirmation")
    }

    // MARK: - Negative controls (P2 — mutation-verified guards)

    /// The pin action is load-bearing: tapping it flips isPinned. (Mutation-verify: replacing
    /// `model.togglePin(for: entry)` with a no-op leaves isPinned false → this assertion RED.)
    func testNegativeControl_pinActionTogglesPin() throws {
        let model = try makeVM(state: state(entry: entry(isPinned: false)))
        let view = menu(for: entry(isPinned: false), model: model)
        let before = model.isPinned(view.entry)
        try view.inspect().find(button: "Pin to Top").tap()
        XCTAssertNotEqual(before, model.isPinned(view.entry), "the pin action must change the pinned state")
    }

    /// The Move action is load-bearing: tapping the target project's Button changes the entry's
    /// projectId. (Mutation-verify: making `moveSession` a no-op leaves projectId == A → RED.)
    func testNegativeControl_moveActionChangesProject() throws {
        let model = try makeVM(state: twoProjectState(entry: entry(projectId: Self.projectA)))
        let view = menu(for: entry(projectId: Self.projectA), model: model)
        let before = model.state.processEntries.first?.projectId
        try view.inspect().find(button: "Backend").tap()
        XCTAssertNotEqual(before, model.state.processEntries.first?.projectId,
                          "the move action must change the entry's project")
    }
}
#endif
