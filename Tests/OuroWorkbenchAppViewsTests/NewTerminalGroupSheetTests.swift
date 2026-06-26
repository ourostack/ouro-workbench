#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B4 — `NewTerminalGroupSheet` (20 uncovered regions: the entire view body +
/// its `@State` defaults were never driven by the campaign).
///
/// The sheet has NO `init` seam — its `rootPath` `@State` defaults to
/// `FileManager.default.homeDirectoryForCurrentUser.path`, so the captured Root-Path
/// `TextField` necessarily renders the machine home (`/Users/<name>`). That value is
/// the ONE machine-specific, non-deterministic node in the tree (the `@State`-no-init
/// path-leak the cluster flagged). We DRIVE the body (covering every render region),
/// ASSERT the deterministic captured content directly, and pin a snapshot of the
/// tree with the home path MASKED to a fixed token (`<HOME>`) — so the committed
/// reference is byte-identical across machines (P3) AND leaks no `/Users/<name>` (the
/// masked ref contains no machine path), while still asserting the real rendered
/// structure and being mutation-verified.
///
/// **Genuinely-unreachable (recorded carve candidates, NOT driven):** the `.onChange`
/// autofill closure, the Choose/Create button ACTION closures (`chooseRootPath()` →
/// `NSOpenPanel.runModal()`, `model.createGroup` guard), and `chooseRootPath()` itself
/// are never invoked by a render pass. Recorded for Unit 3.
@MainActor
final class NewTerminalGroupSheetTests: XCTestCase {

    /// The machine home path the `@State` default reads — masked out of the committed
    /// reference so the ref is deterministic and leak-free.
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b4newgrp-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    private func sheet() throws -> NewTerminalGroupSheet {
        NewTerminalGroupSheet(model: try makeVM())
    }

    /// The captured tree with the machine home masked to `<HOME>` — deterministic
    /// and leak-free for the committed reference.
    private func maskedTree() throws -> String {
        let tree = try ViewSnapshotHost.snapshotText(of: try sheet())
        return tree.replacingOccurrences(of: Self.home, with: "<HOME>")
    }

    // MARK: - Drive the body + assert the deterministic content

    func testSheet_rendersForm() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: try sheet())
        XCTAssertTrue(tree.contains(#"text="New Workspace""#),
                      "the sheet title (WorkbenchSurfacePolicy.newWorkspaceSheetTitle):\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Choose""#), "the Choose button label:\n\(tree)")
        XCTAssertTrue(tree.contains(#"image="folder""#), "the Choose folder glyph:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Cancel""#) && tree.contains(#"text="Create""#),
                      "the Cancel/Create buttons:\n\(tree)")
        XCTAssertTrue(tree.contains(#"image="checkmark""#), "the Create checkmark glyph:\n\(tree)")
        let store = ViewSnapshotStore.default(testFilePath: #filePath)
        try assertViewSnapshotText(try maskedTree(), named: "NewTerminalGroupSheet.form", store: store)
    }

    // MARK: - Path-leak: the masked reference carries no machine path (P3)

    func testSheet_maskedReference_hasNoMachinePath() throws {
        let masked = try maskedTree()
        XCTAssertFalse(masked.contains("/Users/"),
                       "the masked reference must contain no /Users/ machine-path:\n\(masked)")
        XCTAssertTrue(masked.contains(#"text="<HOME>""#),
                      "the Root-Path field's home default is masked to <HOME>:\n\(masked)")
    }

    func testSheet_deterministic_byteIdenticalTwice() throws {
        XCTAssertEqual(try maskedTree(), try maskedTree(),
                       "the masked tree must serialize byte-identically twice")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The masked tree pins the rendered title + the empty Name field + the masked
    /// Root-Path default. A content mutation to any pinned node flips it (verified by
    /// mutating the "New Workspace" title source -> RED -> revert).
    func testSheet_negativeControl_pinsRenderedTitle() throws {
        XCTAssertTrue(try maskedTree().contains(#"Text kind=static text="New Workspace""#),
                      "the title is a pinned content node the mutation-verify breaks")
    }
}
#endif
