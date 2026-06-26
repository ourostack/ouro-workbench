#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C11-6 — `NewTerminalSessionSheet` (RECONFIRM → resolved LOGIC; the home-path
/// leak view).
///
/// The planning audit binned this as RECONFIRM ("attribute-only-leaning") because
/// its only NOMINAL branch is `.disabled(!canCreate)` (attribute-only → dropped by
/// the host) plus an `onChange`/`guard` (not a render branch). BUT the host DOES
/// capture `TextField` bound values via `input()` (AN-002), and the sheet renders
/// `TextField("Working Directory", text: $workingDirectory)` whose value is seeded
/// from `model.selectedProject?.rootPath ?? home` — a DATA-DRIVEN captured value
/// that flips with the selected project (the `SidebarCountBadge` value-flip class).
/// So it is genuinely LOGIC and is COVERED. (Reconfirmed by mutation below.)
///
/// **Home-path leak (the cluster's named MEDIUM hazard) — pinned.** The `@State`
/// default is `FileManager.default.homeDirectoryForCurrentUser.path` (and the init
/// override falls back to it when `selectedProject == nil`) → with no project the
/// captured Working-Directory TextField leaks `/Users/<name>/`. The fixture
/// provenance-builds `model.selectedProject` with a FIXED relative `rootPath`
/// (`/tmp/u4`) so no `/Users/…` reaches the tree, defended by `!contains("/Users/")`.
/// This is the same class as the C6 Q3 `NSFullUserName()` landmine, different view.
@MainActor
final class NewTerminalSessionSheetTests: XCTestCase {

    private static let projectId = UUID(uuidString: "C1100006-0000-0000-0000-0000000000A6")!

    /// A VM whose selected project has a FIXED relative rootPath — so the sheet's
    /// `@State workingDirectory` init reads `/tmp/u4`, never the machine home.
    private func makeVM(rootPath: String) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c11newterm-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            selectedProjectId: Self.projectId,
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: rootPath)]))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    private func view(rootPath: String) throws -> NewTerminalSessionSheet {
        NewTerminalSessionSheet(model: try makeVM(rootPath: rootPath))
    }

    // MARK: - Enumerated state-set (the working-directory value-flip)

    func testSheet_withProject_workingDirectoryFromProjectRoot() throws {
        let view = try view(rootPath: "/tmp/u4")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="New Terminal""#), "the sheet title:\n\(tree)")
        // The captured TextField bound value is seeded from the project root.
        XCTAssertTrue(tree.contains(#"kind=editable text="/tmp/u4""#),
                      "the Working Directory field seeds from selectedProject.rootPath:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Create""#) && tree.contains(#"text="Cancel""#),
                      "the static form buttons render:\n\(tree)")
        try assertViewSnapshot(of: view, named: "NewTerminalSessionSheet.withProject")
    }

    func testSheet_differentProjectRoot_fieldFlips() throws {
        let view = try view(rootPath: "/tmp/u4-other")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"kind=editable text="/tmp/u4-other""#),
                      "the field tracks the (different) project root:\n\(tree)")
        try assertViewSnapshot(of: view, named: "NewTerminalSessionSheet.otherProject")
    }

    // MARK: - Home-path leak defense (the named MEDIUM hazard)

    func testSheet_noHomePathLeak() throws {
        for root in ["/tmp/u4", "/tmp/u4-other"] {
            let tree = try ViewSnapshotHost.snapshotText(of: try view(rootPath: root))
            XCTAssertFalse(tree.contains("/Users/"),
                           "the Working Directory field must NOT leak /Users/<name>/:\n\(tree)")
            XCTAssertFalse(tree.contains("/var/folders/"), "no temp-path leak:\n\(tree)")
        }
    }

    func testSheet_deterministic_byteIdenticalTwice() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try view(rootPath: "/tmp/u4"))
        let b = try ViewSnapshotHost.snapshotText(of: try view(rootPath: "/tmp/u4"))
        XCTAssertEqual(a, b, "the sheet must serialize byte-identically twice")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The Working-Directory captured TextField value is the data-driven
    /// discriminator: a different project root flips it. (Reconfirmed LOGIC, not
    /// branchless: the value tracks model.selectedProject.rootPath.)
    func testSheet_negativeControl_workingDirectoryValueFlips() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try view(rootPath: "/tmp/u4"))
        let b = try ViewSnapshotHost.snapshotText(of: try view(rootPath: "/tmp/u4-other"))
        XCTAssertNotEqual(a, b, "the working-directory field must flip with the project root")
        XCTAssertTrue(a.contains(#"text="/tmp/u4""#))
        XCTAssertTrue(b.contains(#"text="/tmp/u4-other""#))
    }
}
#endif
