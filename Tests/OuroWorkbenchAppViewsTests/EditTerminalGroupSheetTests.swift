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
/// **U5 B4-REDO:** the original B4 recorded the Cancel/Save button ACTION closures as
/// "carves" under the obsolete "snapshots can't test interaction" assumption. ViewInspector
/// 0.10.3 DOES invoke action-closures, so they are now DRIVEN (see the B4-REDO section): the
/// init already seeds non-empty name+root → Save enabled, and a VM that CONTAINS the project
/// lets `renameGroup`'s `firstIndex` find it, so both Save guard arms (success/dismiss and
/// the validateOnDisk-fail return) are reachable.
///
/// **Genuinely-unreachable (the only remaining carves):** the Choose button action
/// `{ chooseRootPath() }` + `chooseRootPath()` itself + its `panel.runModal()` branches —
/// `NSOpenPanel().runModal()` is a blocking live-GUI modal, categorically untestable
/// in-process.
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

    // MARK: - U5 B4-REDO — drive the Cancel/Save button-action closures (originally WRONGLY carved)
    //
    // ViewInspector 0.10.3 invokes action-closures, so the Cancel + Save button ACTION closures
    // (`dismiss()`, `model.renameGroup` guard, `dismiss()`) the original B4 recorded as "carves"
    // are DRIVABLE. The init already seeds `@State` from the project (name + rootPath non-empty →
    // Save is ENABLED), so we drive both Save guard arms: a project IN state + a REAL root →
    // renameGroup succeeds (guard-pass → dismiss); a project IN state + a non-existent root →
    // renameGroup fails (guard-fail → return). The only remaining carves are the Choose button /
    // `chooseRootPath()` / its `NSOpenPanel.runModal()` blocking-modal path.

    private func makeRealDirectory() throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b4redo-editgrproot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// A VM whose state CONTAINS the project, so `renameGroup`'s `firstIndex(project.id)`
    /// guard finds it — the prerequisite for reaching the validateOnDisk decision.
    private func vmContaining(_ project: WorkbenchProject) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b4redo-editgrp-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: [project]))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    // MARK: - the Cancel button action `{ dismiss() }`

    func testSheet_cancelTap_invokesDismiss() throws {
        let view = try sheet(project: project())
        XCTAssertNoThrow(try view.inspect().find(button: "Cancel").tap(),
                         "the Cancel action closure (dismiss()) executes")
    }

    // MARK: - Save button: the guard-PASS (success) arm → renameGroup + dismiss

    func testSheet_saveTap_validRealRoot_renamesAndDismisses() throws {
        let proj = project(name: "Home", rootPath: "/tmp/u4")
        let model = try vmContaining(proj)
        let realRoot = try makeRealDirectory()
        // Seed the sheet with a NEW name + a real on-disk root, both non-empty → Save enabled.
        let view = EditTerminalGroupSheet(model: model, project: project(name: "Renamed", rootPath: realRoot))
        try view.inspect().find(button: "Save").tap()
        XCTAssertEqual(model.state.projects.first?.name, "Renamed",
                       "valid Save → renameGroup writes the new project name (then dismiss())")
        XCTAssertEqual(model.state.projects.first?.rootPath, realRoot, "and the new root")
    }

    // MARK: - Save button: the guard-FAIL arm → renameGroup returns false → return

    func testSheet_saveTap_nonexistentRoot_guardFails() throws {
        let proj = project(name: "Home", rootPath: "/tmp/u4")
        let model = try vmContaining(proj)
        let missingRoot = "/tmp/b4redo-editgrp-missing-\(UUID().uuidString)"
        // Both fields non-empty → Save enabled; the non-existent root fails validateOnDisk →
        // renameGroup returns false → the `guard … else { return }` FALSE arm (no rename).
        let view = EditTerminalGroupSheet(model: model, project: project(name: "Renamed", rootPath: missingRoot))
        XCTAssertNil(model.errorMessage, "provenance: no error before")
        try view.inspect().find(button: "Save").tap()
        XCTAssertNotNil(model.errorMessage, "non-existent root → renameGroup fails → errorMessage set")
        XCTAssertEqual(model.state.projects.first?.name, "Home", "the name is NOT changed on the fail arm")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// Save is load-bearing: a valid edit writes the new name. (Mutation-verify: replacing
    /// `model.renameGroup(...)` with a constant false leaves the old name → RED.)
    func testSheet_negativeControl_validSaveRenames() throws {
        let proj = project(name: "Home", rootPath: "/tmp/u4")
        let model = try vmContaining(proj)
        let realRoot = try makeRealDirectory()
        try EditTerminalGroupSheet(model: model, project: project(name: "Edited", rootPath: realRoot))
            .inspect().find(button: "Save").tap()
        XCTAssertEqual(model.state.projects.first?.name, "Edited", "valid Save must write the new name")
    }
}
#endif
