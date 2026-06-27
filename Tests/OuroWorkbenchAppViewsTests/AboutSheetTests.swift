#if os(macOS)
import XCTest
import SwiftUI
import OuroWorkbenchCore
import OuroWorkbenchShellAdapter
@testable import OuroWorkbenchAppViews

/// Coverage-tightening (Class 7) — `AboutSheet` (residual-baseline.md K1 #8, the "live
/// build-hash arm"). `buildHash` read `Bundle.main.infoDictionary?["CFBundleVersion"]` live,
/// so the about presentation + version-line render were environment-dependent and carved.
///
/// The new `init(model:buildHash:)` seam injects a FIXED hash, so the `aboutPresentation` /
/// `body` / version-line render is driven deterministically. The `openRepository`
/// (NSWorkspace) and `copyVersion` (NSPasteboard) action closures stay carved (in-process I/O).
@MainActor
final class AboutSheetTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c7about-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    /// The injected build hash flows into the about presentation's version line, which renders
    /// in the sheet body — driven deterministically (vs the live `CFBundleVersion`).
    func testAbout_injectedBuildHash_rendersVersionLine() throws {
        let view = AboutSheet(model: try makeVM(), buildHash: "abc1234d")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        // The version line is "Version <ver> - Build <buildHash>".
        let expected = WorkbenchShellAboutPresentation(buildHash: "abc1234d").versionLine
        XCTAssertTrue(expected.contains("Build abc1234d"), "provenance: the version line carries the hash")
        XCTAssertTrue(tree.contains("abc1234d"), "the injected build hash renders in the about view:\n\(tree)")
    }

    /// The build hash flips the rendered version line (negative control): a different injected
    /// hash flips the tree.
    func testAbout_negativeControl_buildHashFlipsTree() throws {
        let a = try ViewSnapshotHost.snapshotText(of: AboutSheet(model: try makeVM(), buildHash: "hash-aaaa"))
        let b = try ViewSnapshotHost.snapshotText(of: AboutSheet(model: try makeVM(), buildHash: "hash-bbbb"))
        XCTAssertNotEqual(a, b, "the build hash must flip the rendered version line")
        XCTAssertTrue(a.contains("hash-aaaa") && !a.contains("hash-bbbb"))
        XCTAssertTrue(b.contains("hash-bbbb") && !b.contains("hash-aaaa"))
    }

    /// Determinism + no machine-path leak.
    func testAbout_deterministic_noLeak() throws {
        let a = try ViewSnapshotHost.snapshotText(of: AboutSheet(model: try makeVM(), buildHash: "fixed"))
        let b = try ViewSnapshotHost.snapshotText(of: AboutSheet(model: try makeVM(), buildHash: "fixed"))
        XCTAssertEqual(a, b, "the about view must serialize byte-identically twice for a fixed hash")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
    }

    /// The default `init(model:)` still resolves a build hash (the prod path) and renders.
    func testAbout_defaultInit_rendersWithoutCrash() throws {
        XCTAssertNoThrow(try ViewSnapshotHost.snapshotText(of: AboutSheet(model: try makeVM())),
                         "the default init (live CFBundleVersion ?? dev) renders")
    }
}
#endif
