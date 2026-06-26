#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C6-5 — `WorkbenchOnboardingSheet` (`:6434`) initial-page composite.
///
/// **Re-confirm: NOT a shell-allowlist candidate.** Unlike `WorkbenchRootView` (the
/// window/scene shell with a `@StateObject` + `NavigationSplitView` and no data-state seam),
/// this sheet has a REAL data-state seam: it takes an injected `model` and composes
/// `OnboardingFlowHeader` + `OnboardingPageContent` + the nav row (`primaryActionTitle` /
/// `primaryActionImage` / `OnboardingProgressDots`), all driven by hermetic model state. It hosts
/// deterministically under `inspect()` and its initial `.boss` page renders a real composite —
/// so it stays IN U4 scope (covered), not allowlisted.
///
/// **Initial-page seam (AN-006).** `@State page` defaults to `.boss` with no init seam; the
/// `.connect` / `.importWork` pages are reachable ONLY by firing the in-view Back / Next Button
/// closures that ViewInspector's synchronous `inspect()` CANNOT fire (the C4 `DecisionInboxSheet
/// showFullLog` / `DecisionLogRow taught` pattern). So this test snapshots the GENUINE initial
/// `.boss` composite; the other two pages are RECORDED as in-view-Button-only reachable, NOT
/// fabricated. (`OnboardingPageContent`'s `.connect` / `.importWork` children ARE covered directly
/// in C6-4 via the injected-page seam — so no page goes uncovered.)
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` store seam (AN-001 dual-injection). The
/// `.task` (refresh*) / `.onDisappear` (rollback) effects do NOT run under `inspect()`, so the
/// snapshot is the model's deterministic initial state. NO fabricated state.
///
/// **Determinism (P3).** No clock / path / machine value reaches the captured tree under the
/// hermetic VM. Byte-identical twice; no `/Users/` leak.
///
/// **Non-vacuity (P2).** The `.boss`-page primary button title ("Continue", `:6511`) is a captured
/// node driven by the `switch page` in `primaryActionTitle`. The negative control mutates it.
@MainActor
final class WorkbenchOnboardingSheetTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c6-onbsheet-\(UUID().uuidString)", isDirectory: true)
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

    private func sheet() throws -> WorkbenchOnboardingSheet {
        WorkbenchOnboardingSheet(model: try makeVM())
    }

    // MARK: - Initial-page composite

    /// The genuine initial `.boss` page: the header (Choose Boss), the boss-choice content, and
    /// the nav row with the "Continue" primary.
    func testOnboardingSheet_initialBossPage() throws {
        try assertViewSnapshot(of: try sheet(), named: "WorkbenchOnboardingSheet.initialBossPage")
    }

    // MARK: - Determinism (P3)

    func testOnboardingSheet_determinism_byteIdenticalTwiceNoLeak() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try sheet())
        let b = try ViewSnapshotHost.snapshotText(of: try sheet())
        XCTAssertEqual(a, b, "the initial boss page must be byte-identical twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
    }

    // MARK: - Provenance: the boss page renders the composite (header + content + Continue)

    func testOnboardingSheet_bossPageComposite() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: try sheet())
        XCTAssertTrue(tree.contains("Choose Boss"), "the header title renders the .boss page:\n\(tree)")
        XCTAssertTrue(tree.contains("Continue"), "the .boss-page primary reads Continue")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The `.boss`-page `primaryActionTitle` ("Continue") is a captured node driven by the
    /// `switch page` — break it and the composite snapshot + the provenance assertion go RED.
    func testOnboardingSheet_negativeControl_primaryTitleIsCaptured() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: try sheet())
        XCTAssertTrue(tree.contains("Continue"),
                      "the .boss-page primary title renders (mutating it to anything else makes this RED):\n\(tree)")
        // The header's "Cancel" (not-completed) also renders alongside the Continue primary —
        // proving the composite (header + nav) is captured, not just one child.
        XCTAssertTrue(tree.contains("Cancel"), "the not-completed header dismiss label renders")
    }
}
#endif
