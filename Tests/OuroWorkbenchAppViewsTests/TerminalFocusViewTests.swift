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
}
#endif
