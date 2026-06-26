#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B4 — `EditTerminalGroupSheet` (17 uncovered regions: the whole view body +
/// its `init` were never driven by the campaign).
///
/// Unlike the New-group sheet, this one HAS an `init(model:project:)` that seeds its
/// `@State name`/`@State rootPath` from the supplied `WorkbenchProject` — a real seam.
/// A FIXED relative `/tmp/u4` `rootPath` keeps `/Users/` out of the captured tree
/// (defended by `!contains("/Users/")`), so a full byte-identical snapshot reference
/// is recordable + deterministic.
///
/// **Genuinely-unreachable (recorded carve candidates, NOT driven):** the Choose/Save
/// button ACTION closures (`chooseRootPath()` → `NSOpenPanel.runModal()`, the
/// `model.renameGroup` guard), and `chooseRootPath()` itself are never invoked by a
/// render pass. Recorded for Unit 3.
@MainActor
final class EditTerminalGroupSheetTests: XCTestCase {

    private static let projectId = UUID(uuidString: "B4ED7E51-0000-0000-0000-0000000000B1")!

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b4editgrp-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    /// A FIXED project — its `name`/`rootPath` seed the sheet's `@State` via the init.
    private func project(name: String = "Home", rootPath: String = "/tmp/u4") -> WorkbenchProject {
        WorkbenchProject(id: Self.projectId, name: name, rootPath: rootPath)
    }

    private func sheet(project: WorkbenchProject) throws -> EditTerminalGroupSheet {
        EditTerminalGroupSheet(model: try makeVM(), project: project)
    }

    // MARK: - init seeds the @State from the project → drive the body

    func testSheet_seedsFromProject() throws {
        let view = try sheet(project: project())
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="Edit Workspace""#),
                      "the sheet title (WorkbenchSurfacePolicy.editWorkspaceSheetTitle):\n\(tree)")
        XCTAssertTrue(tree.contains(#"kind=editable text="Home""#),
                      "the Name field seeds from project.name:\n\(tree)")
        XCTAssertTrue(tree.contains(#"kind=editable text="/tmp/u4""#),
                      "the Root Path field seeds from project.rootPath:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Choose""#) && tree.contains(#"text="Cancel""#) && tree.contains(#"text="Save""#),
                      "the static form buttons render:\n\(tree)")
        try assertViewSnapshot(of: view, named: "EditTerminalGroupSheet.seeded")
    }

    // MARK: - Path-leak defense (P3)

    func testSheet_noMachinePathLeak() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: try sheet(project: project()))
        XCTAssertFalse(tree.contains("/Users/"), "no /Users/ machine-path leak:\n\(tree)")
        XCTAssertFalse(tree.contains("/var/folders/"), "no temp-dir path leak:\n\(tree)")
    }

    func testSheet_deterministic_byteIdenticalTwice() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try sheet(project: project()))
        let b = try ViewSnapshotHost.snapshotText(of: try sheet(project: project()))
        XCTAssertEqual(a, b, "the sheet must serialize byte-identically twice")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The project-seeded Name/Root-Path fields are the data-driven discriminators:
    /// a different project flips the captured TextField values.
    func testSheet_negativeControl_fieldsFlipWithProject() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try sheet(project: project(name: "Home", rootPath: "/tmp/u4")))
        let b = try ViewSnapshotHost.snapshotText(of: try sheet(project: project(name: "Work", rootPath: "/tmp/u4-other")))
        XCTAssertNotEqual(a, b, "the Name/Root-Path fields must flip with the project")
        XCTAssertTrue(a.contains(#"text="Home""#) && a.contains(#"text="/tmp/u4""#))
        XCTAssertTrue(b.contains(#"text="Work""#) && b.contains(#"text="/tmp/u4-other""#))
    }
}
#endif
