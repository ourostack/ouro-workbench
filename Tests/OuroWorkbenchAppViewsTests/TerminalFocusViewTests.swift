#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B4 — `TerminalFocusView` (17 uncovered regions: the full-screen terminal focus
/// chrome was never driven by the campaign).
///
/// The view renders a live `TerminalPane(session:)` (an `NSViewRepresentable` live
/// pseudoterminal — the D3-class AppKit path ViewInspector treats as opaque, never
/// launched) PLUS a floating control overlay: `Text(entry.name)` and six action
/// buttons carrying accessibility labels (Exit Full Screen / Redraw / Ctrl-C / Esc /
/// EOF / Stop). That overlay IS capturable, so we DRIVE the chrome through the proven
/// live-session seam: a real `TerminalSessionController` built from a real
/// `TerminalCommandPlan` WITHOUT calling `start()` (no process spawns; `transcriptPath:
/// nil` → file-free + path-leak-free), the same seam `TerminalRowContextMenuStandalone`
/// uses. The asserting ref pins the entry-name Text + the six button a11y labels.
///
/// **Genuinely-unreachable (recorded carve candidates, NOT driven):**
///   - `TerminalPane(session:)` — the live `NSViewRepresentable` PTY pane (D3 carve);
///   - the six button ACTION closures (`exitTerminalFocus`/`redrawTerminal`/`sendControlC`
///     /`sendEscape`/`sendEOF`/`requestStop`) and the `.onAppear` focus/redraw-burst
///     closure — never invoked by a render pass.
/// Recorded for Unit 3.
@MainActor
final class TerminalFocusViewTests: XCTestCase {

    private static let entryId = UUID(uuidString: "B4F0C051-0000-0000-0000-0000000000F1")!
    private static let projectId = UUID(uuidString: "B4F0C051-0000-0000-0000-0000000000A1")!

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b4focus-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            processEntries: [entry()]))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    private func entry(name: String = "build") -> ProcessEntry {
        ProcessEntry(
            id: Self.entryId, projectId: Self.projectId, name: name,
            kind: .shell, executable: "/bin/zsh", workingDirectory: "/tmp/u4")
    }

    /// A real controller built from a real plan, WITHOUT `start()` — the proven
    /// live-session seam (no process, no transcript file, no path leak).
    private func session(for entry: ProcessEntry) throws -> TerminalSessionController {
        let plan = TerminalCommandPlan(
            entryId: entry.id,
            executable: "/bin/zsh",
            arguments: [],
            workingDirectory: "/tmp/u4",
            reason: "test focus session")
        return try TerminalSessionController(
            plan: plan, onStarted: { _ in }, onOutput: {}, onTerminated: { _ in })
    }

    private func focusView(name: String = "build") throws -> TerminalFocusView {
        let model = try makeVM()
        let e = entry(name: name)
        return TerminalFocusView(entry: e, session: try session(for: e), model: model)
    }

    // MARK: - Drive the focus chrome (the control overlay)

    func testFocus_rendersControlOverlay() throws {
        let view = try focusView(name: "build")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="build""#),
                      "the entry-name title in the overlay:\n\(tree)")
        // The six control buttons each carry an accessibility label.
        for label in ["Exit Full Screen", "Redraw", "Ctrl-C", "Esc", "EOF", "Stop"] {
            XCTAssertTrue(tree.contains(#"label="\#(label)""#),
                          "the \(label) control button a11y label:\n\(tree)")
        }
        try assertViewSnapshot(of: view, named: "TerminalFocusView.controlOverlay")
    }

    // MARK: - Path-leak defense (P3)

    func testFocus_noMachinePathLeak() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: try focusView())
        XCTAssertFalse(tree.contains("/Users/"), "no /Users/ machine-path leak:\n\(tree)")
        XCTAssertFalse(tree.contains("/var/folders/"), "no temp-dir path leak:\n\(tree)")
    }

    func testFocus_deterministic_byteIdenticalTwice() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try focusView())
        let b = try ViewSnapshotHost.snapshotText(of: try focusView())
        XCTAssertEqual(a, b, "the focus chrome must serialize byte-identically twice")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The overlay title is `Text(entry.name)` — a data-driven node that flips with
    /// the entry. A different entry name flips the captured title.
    func testFocus_negativeControl_titleFlipsWithEntry() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try focusView(name: "build"))
        let b = try ViewSnapshotHost.snapshotText(of: try focusView(name: "deploy"))
        XCTAssertNotEqual(a, b, "the overlay title must flip with the entry name")
        XCTAssertTrue(a.contains(#"text="build""#))
        XCTAssertTrue(b.contains(#"text="deploy""#))
    }

    // MARK: - U5 B4-REDO — drive the six control-button actions + onAppear (originally carved)
    //
    // ViewInspector 0.10.3 invokes action-closures, so the six control buttons
    // (Exit Full Screen / Redraw / Ctrl-C / Esc / EOF / Stop) and the `.onAppear`
    // closure the original B4 recorded as "carves" are DRIVABLE. Each send button routes
    // through a model method that guards on `activeSessions[entry.id]`, so we REGISTER the
    // (un-started, no-PTY) live-session controller — the proven no-spawn seam — and tap.
    // The send actions record an action-log entry (the asserted side-effect); Exit sets
    // terminalFocusEntryID nil; Stop on a non-idle live session sets pendingStopSession.

    /// A VM with the entry in state AND its (un-started) controller registered in
    /// `activeSessions`, so the send/redraw methods take their success arm.
    private func liveFocusView(attention: AttentionState = .waitingOnHuman)
        throws -> (WorkbenchViewModel, ProcessEntry, TerminalFocusView) {
        let model = try makeVM()
        var e = entry()
        e.attention = attention
        // Seed the (possibly-attention-updated) entry into state so updateEntry finds it.
        model.state.processEntries = [e]
        let session = try session(for: e)
        model.activeSessions[e.id] = session
        return (model, e, TerminalFocusView(entry: e, session: session, model: model))
    }

    /// The six control buttons are image-only (an `Image(systemName:)` label + an
    /// `.accessibilityLabel`), so `find(button:)` (which matches button TEXT) can't reach
    /// them. Find by the contained SF-symbol name instead.
    private func tapControl(_ view: TerminalFocusView, systemImage: String) throws {
        try view.inspect().find(ViewType.Button.self, where: { b in
            (try? b.labelView().image().actualImage().name()) == systemImage
        }).tap()
    }

    func testFocus_exitFullScreenTap_clearsFocus() throws {
        let (model, _, view) = try liveFocusView()
        model.terminalFocusEntryID = Self.entryId  // provenance: focused
        try tapControl(view, systemImage: "arrow.down.right.and.arrow.up.left")
        XCTAssertNil(model.terminalFocusEntryID, "Exit Full Screen → exitTerminalFocus clears the focus id")
    }

    func testFocus_redrawTap_recordsActionLog() throws {
        let (model, _, view) = try liveFocusView()
        let before = model.state.actionLog.count
        try tapControl(view, systemImage: "arrow.clockwise")
        XCTAssertEqual(model.state.actionLog.count, before + 1, "Redraw tap records an action log")
        XCTAssertEqual(model.state.actionLog.first?.action, "redrawTerminal", "the Redraw action")
    }

    func testFocus_ctrlCTap_recordsActionLog() throws {
        let (model, _, view) = try liveFocusView()
        try tapControl(view, systemImage: "command")
        XCTAssertEqual(model.state.actionLog.first?.action, "sendControlC", "Ctrl-C tap → sendControlC")
    }

    func testFocus_escTap_recordsActionLog() throws {
        let (model, _, view) = try liveFocusView()
        try tapControl(view, systemImage: "escape")
        XCTAssertEqual(model.state.actionLog.first?.action, "sendEscape", "Esc tap → sendEscape")
    }

    func testFocus_eofTap_recordsActionLog() throws {
        let (model, _, view) = try liveFocusView()
        try tapControl(view, systemImage: "eject")
        XCTAssertEqual(model.state.actionLog.first?.action, "sendEOF", "EOF tap → sendEOF")
    }

    func testFocus_stopTap_setsPendingStop() throws {
        // A live session with non-idle attention → requestStop → the confirmation gate
        // (pendingStopSession), NOT an immediate terminate.
        let (model, e, view) = try liveFocusView(attention: .waitingOnHuman)
        XCTAssertNil(model.pendingStopSession, "no pending stop before tap")
        try tapControl(view, systemImage: "stop.fill")
        XCTAssertEqual(model.pendingStopSession?.id, e.id,
                       "Stop tap → requestStop sets pendingStopSession (live agent → confirmation)")
    }

    func testFocus_onAppear_invokesFocusAndRedrawBurst() throws {
        // The root ZStack's `.onAppear { session.focusInput(); session.redrawDisplayBurst(...) }`.
        // Both schedule on the main queue (deferred) → no synchronous PTY work; invoking the
        // closure covers the region and must not throw.
        let (_, _, view) = try liveFocusView()
        XCTAssertNoThrow(try view.inspect().zStack().callOnAppear(),
                         "the onAppear focus/redraw-burst closure executes")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// Exit Full Screen is load-bearing: it clears the focus id. (Mutation-verify: replacing
    /// `model.exitTerminalFocus()` with a no-op leaves terminalFocusEntryID set → RED.)
    func testFocus_negativeControl_exitClearsFocus() throws {
        let (model, _, view) = try liveFocusView()
        model.terminalFocusEntryID = Self.entryId
        try tapControl(view, systemImage: "arrow.down.right.and.arrow.up.left")
        XCTAssertNil(model.terminalFocusEntryID, "Exit must clear the terminal-focus id")
    }
}
#endif
