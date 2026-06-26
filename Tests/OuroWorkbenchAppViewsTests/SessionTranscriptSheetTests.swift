#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B5 — `SessionTranscriptSheet` (`:9260`). One uncovered region: `L9276:32` —
/// the `Button("Done") { dismiss() }` ACTION closure. The campaign drove the sheet
/// chrome + the `if let tail` / else transcript arms but never INVOKED the Done
/// button (ViewInspector descends the label, not the action, unless `.tap()` is
/// called). The corrected B5 recipe DRIVES it: `find(button: "Done").tap()` executes
/// the `{ dismiss() }` closure, coloring the region.
///
/// `dismiss()` is `@Environment(\.dismiss)` — in a non-presented test host it is a
/// no-op with no observable model side-effect, so the closure is genuinely invoked
/// (region driven) but carries no behavioral guard of its own to mutation-verify; the
/// non-vacuity in this file is the rendered chrome (Transcript title + entry-name +
/// Done label), each asserted + mutation-verified.
@MainActor
final class SessionTranscriptSheetTests: XCTestCase {

    private static let entryId = UUID(uuidString: "B5005E70-0000-0000-0000-0000000000E1")!
    private static let projectId = UUID(uuidString: "B5005E70-0000-0000-0000-0000000000A1")!

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b5transcript-\(UUID().uuidString)", isDirectory: true)
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
            kind: .shell, executable: "/bin/zsh", workingDirectory: "/tmp/u5")
    }

    private func sheet(name: String = "build") throws -> SessionTranscriptSheet {
        SessionTranscriptSheet(entry: entry(name: name), model: try makeVM())
    }

    // MARK: - Drive the Done-button ACTION closure (the uncovered L9276 region)

    func testSheet_doneButton_invokesDismissClosure() throws {
        let view = try sheet()
        // INVOCATION: tap the Done button → executes `{ dismiss() }`. The closure
        // runs (region driven); the tap succeeds without throwing.
        XCTAssertNoThrow(try view.inspect().find(button: "Done").tap(),
                         "the Done button's action closure must be invokable")
    }

    // MARK: - Chrome (asserted + the non-vacuity guards)

    func testSheet_rendersChrome() throws {
        let view = try sheet(name: "deploy")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="Transcript""#), "the sheet title:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="deploy""#), "the entry-name subtitle:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Done""#), "the Done button label:\n\(tree)")
        try assertViewSnapshot(of: view, named: "SessionTranscriptSheet.noTranscript")
    }

    // MARK: - Negative control (P2 — the entry-name subtitle flips with the entry)

    func testSheet_negativeControl_entryNameFlips() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try sheet(name: "build"))
        let b = try ViewSnapshotHost.snapshotText(of: try sheet(name: "deploy"))
        XCTAssertNotEqual(a, b, "the entry-name subtitle must flip with the entry")
        XCTAssertTrue(a.contains(#"text="build""#))
        XCTAssertTrue(b.contains(#"text="deploy""#))
    }

    func testSheet_deterministic_noLeak() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try sheet())
        let b = try ViewSnapshotHost.snapshotText(of: try sheet())
        XCTAssertEqual(a, b, "the sheet must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no /Users/ machine-path leak:\n\(a)")
        XCTAssertFalse(a.contains("/var/folders/"), "no temp-dir path leak:\n\(a)")
    }
}
#endif
