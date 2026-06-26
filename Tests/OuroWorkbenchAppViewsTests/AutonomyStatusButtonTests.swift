#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C3-7 — `AutonomyStatusButton` (`:4532`) — the DETERMINISTIC (no-boss neutral) arm.
///
/// The button constructs `@StateObject private var loginItem = LoginItemController()` IN-PLACE
/// (`:4534`) — the same NON-INJECTABLE, machine-local login-item `@StateObject` the
/// `MachineRuntimeView` allowlist carve names. Its `snapshot = model.autonomyReadiness
/// .appending(loginItemCheck)` folds the LIVE login state into `snapshot.state`, and the button
/// label renders `presentation.ttfaText` = `HeaderCalmPresentation.resolve(...).ttfaText`. For a
/// boss-SET machine that text is `"TTFA · \(snapshot.state…)"` — so a clean CI runner
/// (`.appBundleMissing` → a `.blocker` login check → `snapshot.state == .blocked`) would render
/// "TTFA · blocked" where a developer machine (`.enabled` → `.ok`) renders e.g. "TTFA · ready".
/// **That boss-set arm is login-item-tainted and is the allowlist carve (recorded, NOT
/// fabricated — `allowlist-candidates.md` candidate #6).**
///
/// **What IS deterministic — the no-boss neutral arm.** When `state.boss.agentName` is empty
/// (the subtractive-FRE first-run state), `HeaderCalmPresentation.resolve` takes the empty-name
/// branch UNCONDITIONALLY: `ttfaText == "TTFA · off"`, `ttfaStyle == .neutral` — INDEPENDENT of
/// `autonomyState` (and therefore of the login check). So the no-boss button captures a fixed
/// "TTFA · off" `Text` regardless of the live login item — proven by the determinism guard below
/// (two fresh controllers + a boss-less VM → byte-identical). This arm is COVERED.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` (AN-001) with an EMPTY boss name (the
/// real persisted `state.boss.agentName == ""`), driving the calm neutral arm through the real
/// `HeaderCalmPresentation.resolve` Core seam. The leading status `Circle()` contributes no
/// captured node (color is dropped), so the lone captured node is the `ttfaText` `Text`.
@MainActor
final class AutonomyStatusButtonTests: XCTestCase {

    private func makeVM(bossName: String) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c3-asb-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(
            WorkspaceState(boss: BossAgentSelection(agentName: bossName)))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private func button(bossName: String) throws -> AutonomyStatusButton {
        AutonomyStatusButton(model: try makeVM(bossName: bossName))
    }

    // MARK: - Enumerated state-set (the deterministic no-boss neutral arm)

    func testButton_noBoss_neutralArm() throws {
        // Empty boss name → the calm neutral arm → a fixed "TTFA · off", login-independent.
        let view = try button(bossName: "")
        XCTAssertTrue(view.model.state.boss.agentName.isEmpty, "provenance: no boss chosen")
        try assertViewSnapshot(of: view, named: "AutonomyStatusButton.noBoss")
    }

    // MARK: - Determinism (P3) — the no-boss arm is login-item-independent

    /// The no-boss arm is login-item-INDEPENDENT: two FRESH (live-state) controllers + a boss-less
    /// VM render byte-identical trees, so the non-injectable login state never leaks into the
    /// COMMITTED reference, and no machine path appears. (The boss-set arm is the allowlist carve.)
    func testButton_noBoss_loginItemIndependentAndNoLeak() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try button(bossName: ""))
        let b = try ViewSnapshotHost.snapshotText(of: try button(bossName: ""))
        XCTAssertEqual(a, b, "the no-boss arm must be byte-identical across fresh login controllers")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
        XCTAssertTrue(a.contains("TTFA · off"), "the calm neutral pill text:\n\(a)")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The neutral-arm `ttfaText` is the real `HeaderCalmPresentation` empty-name output. Breaking
    /// the empty-name calm branch (or the rendered `ttfaText`) flips this captured node.
    func testButton_negativeControl_neutralPillTextInTree() throws {
        let noBoss = try ViewSnapshotHost.snapshotText(of: try button(bossName: ""))
        XCTAssertTrue(noBoss.contains(#"text="TTFA · off""#),
                      "the no-boss neutral pill text must render:\n\(noBoss)")
    }
}
#endif
