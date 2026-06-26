#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C3-1 — `BossWatchHeaderToggle` (`:4249`) enumerated state-set.
///
/// The view's data-driven branch is `if presentation.isVisible` (`:4259`), where
/// `presentation = model.bossWatchPresentation` = `BossWatchPresentation.resolve(
/// isEnabled: bossWatchIsEnabled, hasUsableBoss: currentBossIsUsable)`. So TWO real
/// model seams drive the captured tree:
///   1. `currentBossIsUsable` — `ouroAgent(named: state.boss.agentName)?.isUsableAsBoss`
///      → flips `isVisible`. With NO usable boss the WHOLE pill is hidden (no captured
///      nodes); with a usable boss the pill renders.
///   2. `bossWatchIsEnabled` — flips `presentation.isOn` → the captured `shortLabel`
///      Text ("Watch On" / "Watch Off"), the `eye.fill`/`eye.slash` Image, and the
///      "Boss Watch On"/"Boss Watch Off" accessibility label.
///
/// **Provenance (P2).** `model` is built via the `makeVM` store seam (a temp
/// `agentBundlesURL` dual-injected → AN-001 hermetic). `currentBossIsUsable` is driven
/// by injecting `model.ouroAgents = [fixed .ready OuroAgentRecord]` matching the saved
/// boss name (the SU-E3 seam — the same `@Published` the inventory scan populates), and
/// `bossWatchIsEnabled` is the real stored `@Published` flag the toggle writes. The
/// presentation strings come from the pure `BossWatchPresentation.resolve` Core seam.
///
/// **Enumerated state-set:**
///   - `hidden`   — no usable boss → `isVisible == false` → empty captured tree.
///   - `watchOff` — usable boss, watch disabled → "Watch Off" + `eye.slash`.
///   - `watchOn`  — usable boss, watch enabled → "Watch On" + `eye.fill`.
@MainActor
final class BossWatchHeaderToggleTests: XCTestCase {

    // MARK: - Hermetic provenance fixture (AN-001-safe)

    private func makeVM(bossName: String) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c3-bwt-\(UUID().uuidString)", isDirectory: true)
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

    /// A FIXED `.ready` record (relative paths; AN-001 hygiene) that resolves the saved
    /// boss name to an installed, usable-as-boss bundle → `currentBossIsUsable == true`.
    private func bossRecord(name: String) -> OuroAgentRecord {
        OuroAgentRecord(
            name: name,
            bundlePath: "AgentBundles/\(name).ouro",
            configPath: "AgentBundles/\(name).ouro/agent.json",
            status: .ready,
            detail: "ready"
        )
    }

    /// Build the toggle for a given (usable-boss, watch-enabled) state through the real seams.
    private func toggle(usableBoss: Bool, watchEnabled: Bool) throws -> BossWatchHeaderToggle {
        let model = try makeVM(bossName: "boss-agent")
        if usableBoss {
            model.ouroAgents = [bossRecord(name: "boss-agent")]   // resolves the boss → usable
        }
        model.bossWatchIsEnabled = watchEnabled
        return BossWatchHeaderToggle(model: model)
    }

    // MARK: - Enumerated state-set

    func testToggle_hidden_noUsableBoss() throws {
        // No injected agent → the saved boss name resolves to nothing → not usable →
        // `presentation.isVisible == false` → the pill (and all its nodes) is hidden.
        let view = try toggle(usableBoss: false, watchEnabled: true)
        XCTAssertFalse(view.model.currentBossIsUsable, "provenance: no usable boss")
        XCTAssertFalse(view.model.bossWatchPresentation.isVisible,
                       "provenance: the pill hides without a usable boss")
        try assertViewSnapshot(of: view, named: "BossWatchHeaderToggle.hidden")
    }

    func testToggle_watchOff() throws {
        let view = try toggle(usableBoss: true, watchEnabled: false)
        XCTAssertTrue(view.model.bossWatchPresentation.isVisible, "provenance: usable boss → visible")
        XCTAssertFalse(view.model.bossWatchPresentation.isOn, "provenance: watch is off")
        XCTAssertEqual(view.model.bossWatchPresentation.shortLabel, "Watch Off")
        try assertViewSnapshot(of: view, named: "BossWatchHeaderToggle.watchOff")
    }

    func testToggle_watchOn() throws {
        let view = try toggle(usableBoss: true, watchEnabled: true)
        XCTAssertTrue(view.model.bossWatchPresentation.isVisible, "provenance: usable boss → visible")
        XCTAssertTrue(view.model.bossWatchPresentation.isOn, "provenance: watch is on")
        XCTAssertEqual(view.model.bossWatchPresentation.shortLabel, "Watch On")
        try assertViewSnapshot(of: view, named: "BossWatchHeaderToggle.watchOn")
    }

    // MARK: - Determinism (P3)

    func testToggle_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, Bool, Bool)] = [
            ("hidden", false, true), ("watchOff", true, false), ("watchOn", true, true)
        ]
        for (name, usable, enabled) in cases {
            let a = try ViewSnapshotHost.snapshotText(of: try toggle(usableBoss: usable, watchEnabled: enabled))
            let b = try ViewSnapshotHost.snapshotText(of: try toggle(usableBoss: usable, watchEnabled: enabled))
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The two real gates flip the captured tree: (a) `isVisible` (usable boss)
    /// renders-vs-hides every node; (b) `isOn` (watch enabled) flips the label + glyph.
    func testToggle_negativeControl_visibilityAndOnOffFlipTree() throws {
        let hidden = try ViewSnapshotHost.snapshotText(of: try toggle(usableBoss: false, watchEnabled: true))
        let off = try ViewSnapshotHost.snapshotText(of: try toggle(usableBoss: true, watchEnabled: false))
        let on = try ViewSnapshotHost.snapshotText(of: try toggle(usableBoss: true, watchEnabled: true))

        // (a) the visibility gate renders vs hides the whole pill.
        XCTAssertNotEqual(hidden, on, "the isVisible gate must drive the tree")
        XCTAssertFalse(hidden.contains("Watch"), "hidden: no pill nodes:\n\(hidden)")
        XCTAssertTrue(on.contains("Watch On"), "visible: the pill renders:\n\(on)")

        // (b) the on/off flip swaps the label + the eye glyph.
        XCTAssertNotEqual(off, on, "the isOn flip must change the tree")
        XCTAssertTrue(off.contains("Watch Off"), "off: 'Watch Off':\n\(off)")
        XCTAssertTrue(off.contains("eye.slash"), "off: the slashed eye:\n\(off)")
        XCTAssertTrue(on.contains("eye.fill"), "on: the filled eye:\n\(on)")
        XCTAssertFalse(on.contains("eye.slash"), "on: no slashed eye:\n\(on)")
    }
}
#endif
