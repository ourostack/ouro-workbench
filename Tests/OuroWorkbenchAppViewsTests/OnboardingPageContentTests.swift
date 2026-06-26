#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C6-4 — `OnboardingPageContent` (`:6677`, widened `private`→`internal`).
///
/// The wizard page-router: a `switch page` (`:6685`) selecting the per-page surface —
///   - `.boss` → `OnboardingBossChoiceView`
///   - `.connect` → `OnboardingReadinessView`
///   - `.importWork` → `OnboardingBossReconstructView`
///
/// ViewInspector DESCENDS the selected child (it's a plain `View` body, not a `.popover{}`/
/// `.contextMenu{}`), so the `switch page` flips the CAPTURED subtree per page — a real
/// logic-bearing branch (each child renders distinct content). The child views themselves are
/// covered by their own clusters; here we pin that the ROUTER selects the right one per page.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` store seam (AN-001 dual-injection); the
/// `OnboardingPage` is the REAL (now-`internal`) wizard-page enum. The children read hermetic
/// model state (no machine reads under the empty temp inventory). NO fabricated state.
///
/// **Determinism (P3).** No clock / path / machine value reaches the captured tree (the AN-001
/// dual-injection keeps the boss/agent reads hermetic). Byte-identical twice; no `/Users/` leak.
///
/// **Non-vacuity (P2).** The `switch page` flips the captured child subtree: each page renders a
/// distinct surface (asserted byte-distinct + a per-page anchor string). The negative control
/// asserts the three trees differ.
@MainActor
final class OnboardingPageContentTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c6-onbpage-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(
            WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private func content(page: WorkbenchOnboardingSheet.OnboardingPage) throws -> OnboardingPageContent {
        OnboardingPageContent(page: page, model: try makeVM())
    }

    // MARK: - Enumerated state-set (the router selects the per-page child)

    func testPageContent_boss() throws {
        try assertViewSnapshot(of: try content(page: .boss), named: "OnboardingPageContent.boss")
    }

    func testPageContent_connect() throws {
        try assertViewSnapshot(of: try content(page: .connect), named: "OnboardingPageContent.connect")
    }

    func testPageContent_importWork() throws {
        try assertViewSnapshot(of: try content(page: .importWork), named: "OnboardingPageContent.importWork")
    }

    // MARK: - Determinism (P3)

    func testPageContent_determinism_byteIdenticalTwiceNoLeak() throws {
        for (name, page) in [("boss", WorkbenchOnboardingSheet.OnboardingPage.boss),
                             ("connect", .connect),
                             ("importWork", .importWork)] {
            let a = try ViewSnapshotHost.snapshotText(of: try content(page: page))
            let b = try ViewSnapshotHost.snapshotText(of: try content(page: page))
            XCTAssertEqual(a, b, "\(name) must be byte-identical twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The `switch page` selects a distinct child subtree per page — the three trees differ.
    func testPageContent_negativeControl_switchFlipsChild() throws {
        let boss = try ViewSnapshotHost.snapshotText(of: try content(page: .boss))
        let connect = try ViewSnapshotHost.snapshotText(of: try content(page: .connect))
        let importWork = try ViewSnapshotHost.snapshotText(of: try content(page: .importWork))

        XCTAssertNotEqual(boss, connect, "the switch must select a distinct child for .boss vs .connect")
        XCTAssertNotEqual(connect, importWork, "the switch must select a distinct child for .connect vs .importWork")
        XCTAssertNotEqual(boss, importWork, "the switch must select a distinct child for .boss vs .importWork")
    }
}
#endif
