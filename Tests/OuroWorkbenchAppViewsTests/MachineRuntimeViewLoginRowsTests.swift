#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// Coverage-tightening (Class 5) — `MachineRuntimeView`'s LOGIN-ITEM rows, previously carved
/// as machine-dependent (the in-place `@StateObject LoginItemController()` read live
/// `~/Applications` / LaunchAgents state). The new `init(model:loginItem:)` seam injects a
/// controller in a KNOWN state (a temp-rooted `LaunchAgentLoginItem`), so the login rows —
/// `Toggle("Open at Login")`, `DashboardStatusLine(loginItem.statusLine)`, and the
/// `if let lastError` Text arm (residual-baseline :10600) — render DETERMINISTICALLY.
///
/// No committed snapshot: instead we assert the rendered login-row markers + the controller's
/// state through the seam. The Support-Diagnostics region stays covered by
/// MachineRuntimeViewCarveTests.
@MainActor
final class MachineRuntimeViewLoginRowsTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c5machine-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    private func loginItem(appExists: Bool = true) -> LaunchAgentLoginItem {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c5login-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let appURL = root.appendingPathComponent("Ouro Workbench.app", isDirectory: true)
        if appExists {
            try? FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        }
        return LaunchAgentLoginItem(appURL: appURL, homeURL: root)
    }

    /// "not registered" status line renders in the login row.
    func testLoginRow_notRegistered_statusLineRenders() throws {
        let view = MachineRuntimeView(
            model: try makeVM(), loginItem: LoginItemController(loginItem: loginItem()))
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("Open at Login"), "the login toggle label renders:\n\(tree)")
        XCTAssertTrue(tree.contains("not registered"), "the 'not registered' status line renders:\n\(tree)")
        XCTAssertTrue(tree.contains("Native Runtime"), "the row label renders")
    }

    /// "enabled" status line after the injected controller installs the plist.
    func testLoginRow_enabled_statusLineRenders() throws {
        let controller = LoginItemController(loginItem: loginItem())
        controller.setEnabled(true)
        XCTAssertEqual(controller.statusLine, "enabled", "provenance: controller is enabled")
        let tree = try ViewSnapshotHost.snapshotText(of: MachineRuntimeView(model: try makeVM(), loginItem: controller))
        XCTAssertTrue(tree.contains("enabled"), "the 'enabled' status line renders:\n\(tree)")
    }

    /// The `if let lastError` Text arm (residual-baseline :10600): an injected controller with a
    /// formatted lastError renders the red error Text.
    func testLoginRow_lastErrorArm_rendersErrorText() throws {
        let controller = LoginItemController(loginItem: loginItem(appExists: false))
        controller.setEnabled(true)   // install throws appBundleMissing → lastError set
        let lastError = try XCTUnwrap(controller.lastError, "provenance: the controller has a lastError")
        XCTAssertTrue(lastError.hasPrefix("Open at Login update failed:"))
        let tree = try ViewSnapshotHost.snapshotText(of: MachineRuntimeView(model: try makeVM(), loginItem: controller))
        XCTAssertTrue(tree.contains("Open at Login update failed:"),
                      "the lastError Text arm renders the error:\n\(tree)")
    }

    /// Negative control: the lastError arm appears ONLY when lastError is set.
    func testLoginRow_negativeControl_lastErrorArmGated() throws {
        let clean = try ViewSnapshotHost.snapshotText(
            of: MachineRuntimeView(model: try makeVM(), loginItem: LoginItemController(loginItem: loginItem())))
        let errored = LoginItemController(loginItem: loginItem(appExists: false))
        errored.setEnabled(true)
        let erroredTree = try ViewSnapshotHost.snapshotText(
            of: MachineRuntimeView(model: try makeVM(), loginItem: errored))
        XCTAssertFalse(clean.contains("Open at Login update failed:"), "clean: no error arm")
        XCTAssertTrue(erroredTree.contains("Open at Login update failed:"), "errored: the error arm renders")
        XCTAssertNotEqual(clean, erroredTree, "the lastError gate flips the tree")
    }
}
#endif
