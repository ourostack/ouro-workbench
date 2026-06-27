#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B9 — `ReleaseUpdateView` (`:10434`) drive-to-100%.
///
/// `ReleaseUpdateView` is a thin public wrapper around `WorkbenchUpdatePanel`
/// (the shared OuroAppShellUI release controls). No prior test CONSTRUCTS this exact
/// public wrapper — so 2 region segments (its `public init(model:)` and `public var
/// body`) were never coloured. Constructing + snapshotting it drives both.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` (AN-001); the wrapped
/// controls render off `model.appShellUpdateState` (a real `@Published`).
///
/// **Carves:** none — the wrapper's `init` + `body` are both driven here.
@MainActor
final class ReleaseUpdateViewInteractionTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b9release-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    /// Constructing `ReleaseUpdateView(model:)` runs its `public init` (`:10437`); snapshotting
    /// it evaluates its `public var body` (`:10441`) → the wrapped `WorkbenchUpdatePanel`.
    func testReleaseUpdateView_constructsAndRenders() throws {
        let model = try makeVM()
        let view = ReleaseUpdateView(model: model)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertFalse(tree.isEmpty, "the release-update wrapper renders a non-empty tree")
        XCTAssertFalse(tree.contains("/Users/"), "no machine-path leak:\n\(tree)")
    }

    func testWorkbenchUpdatePanel_constructsAndRenders() throws {
        let model = try makeVM()
        let tree = try ViewSnapshotHost.snapshotText(of: WorkbenchUpdatePanel(model: model, showTitle: true))

        XCTAssertTrue(tree.contains("Software Updates"), "the shared update panel title renders:\n\(tree)")
        XCTAssertFalse(tree.contains("/Users/"), "no machine-path leak:\n\(tree)")
    }

    func testAboutSheet_constructsAndRendersSharedShellAbout() throws {
        let model = try makeVM()
        let tree = try ViewSnapshotHost.snapshotText(of: AboutSheet(model: model))

        XCTAssertTrue(tree.contains("About Ouro Workbench"), "the shared about surface renders:\n\(tree)")
        XCTAssertTrue(tree.contains("Version"), "the version line renders:\n\(tree)")
        XCTAssertFalse(tree.contains("/Users/"), "no machine-path leak:\n\(tree)")
    }

    /// Determinism (P3): the wrapper serializes byte-identically twice.
    func testReleaseUpdateView_deterministicTwice() throws {
        let model = try makeVM()
        let a = try ViewSnapshotHost.snapshotText(of: ReleaseUpdateView(model: model))
        let b = try ViewSnapshotHost.snapshotText(of: ReleaseUpdateView(model: model))
        XCTAssertEqual(a, b, "the release-update wrapper must serialize byte-identically twice")
    }
}
#endif
