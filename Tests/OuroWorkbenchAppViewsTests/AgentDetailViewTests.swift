#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C7-6 — `AgentDetailView` (`:8079`), the Agents-sidebar detail pane. The agent-detail
/// (path-leak) cluster's composite: it stitches the title strip + (optionally) the inspector
/// panel + the status/lanes/actions cards. The path-leak vector (`AgentInspectorPanel`'s
/// visible `Text(bundlePath)`/`Text(configPath)`) is reachable ONLY through this composite's
/// `if showsInspector` arm — so the fixture uses FIXED, RELATIVE paths and asserts no machine
/// path reaches the captured tree (the cluster's whole point), even though the initial State
/// renders the collapsed (inspector-hidden) arm.
///
/// **Data-driven branch (the composite's one gate):**
///   - `if showsInspector` (`@State private var showsInspector = false`) → the
///     `AgentInspectorPanel` + a `Divider` appear.
///
/// **UNREACHABLE-via-`inspect()` arm (recorded, NOT fabricated — the C4 DecisionLogRow
/// `@State taught` discipline):** `showsInspector == true` is reachable ONLY by firing the
/// title strip's chevron Button, which ViewInspector's synchronous `inspect()` does not fire.
/// So the genuine snapshot is the COLLAPSED arm (the real initial-State render); the expanded
/// arm is covered ELSEWHERE (`AgentInspectorPanelPathLeakTests`, C0 SU-3, snapshots the panel
/// standalone at both its registration arms). We do NOT fabricate an `showsInspector == true`
/// composite snapshot — that would require reaching past the real State seam.
///
/// **Provenance (P2).** `model` via the `makeVM` dual-injection store seam (AN-001). `agent`
/// is a FIXED `OuroAgentRecord` with FIXED, RELATIVE paths AND fixed lanes (so the embedded
/// `LanePanel`s render real provider/model values, exercising the composite end-to-end).
@MainActor
final class AgentDetailViewTests: XCTestCase {

    private func makeVM(bossName: String = "boss") throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c7detail-\(UUID().uuidString)", isDirectory: true)
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

    /// A FIXED record: relative paths (the path-leak fix) + fixed lanes so the composite's
    /// `LanePanel`s render real provider/model values.
    private func record(name: String) -> OuroAgentRecord {
        OuroAgentRecord(
            name: name,
            bundlePath: "AgentBundles/\(name).ouro",
            configPath: "AgentBundles/\(name).ouro/agent.json",
            status: .ready,
            detail: "ready",
            humanFacing: OuroAgentLane(provider: "anthropic", model: "claude-opus-4"),
            agentFacing: OuroAgentLane(provider: "anthropic", model: "claude-sonnet-4")
        )
    }

    private func detail(boss: String, agentName: String) throws -> AgentDetailView {
        AgentDetailView(agent: record(name: agentName), model: try makeVM(bossName: boss))
    }

    // MARK: - Enumerated state-set (the genuine initial-State render)

    /// Non-boss → the collapsed composite: title strip ("Use as Boss") + the status/lanes
    /// cards (no inspector — the `@State showsInspector` initial is `false`).
    func testDetail_collapsedPlain() throws {
        let view = try detail(boss: "someone-else", agentName: "alpha-agent")
        try assertViewSnapshot(of: view, named: "AgentDetailView.collapsedPlain")
    }

    /// The boss composite → the title strip carries the "boss" capsule + the "Boss" action.
    func testDetail_collapsedBoss() throws {
        let view = try detail(boss: "alpha-agent", agentName: "alpha-agent")
        try assertViewSnapshot(of: view, named: "AgentDetailView.collapsedBoss")
    }

    // MARK: - Path-leak defense (P3 — the cluster's whole point)

    /// Even the composite (which can host the path-rendering inspector) leaks NO machine path:
    /// the collapsed arm carries the lanes/title, and the fixed/relative `OuroAgentRecord`
    /// keeps every reachable subtree machine-value-free.
    func testDetail_pathLeakDefense_noMachinePathInTree() throws {
        for (boss, name) in [("someone-else", "alpha-agent"), ("alpha-agent", "alpha-agent")] {
            let tree = try ViewSnapshotHost.snapshotText(of: try detail(boss: boss, agentName: name))
            XCTAssertFalse(tree.contains("/Users/"), "no /Users/ machine-path leak:\n\(tree)")
            XCTAssertFalse(tree.contains("/var/folders/"), "no temp-dir path leak:\n\(tree)")
            XCTAssertTrue(tree.contains(#"text="anthropic""#), "the composite renders the lanes:\n\(tree)")
        }
    }

    // MARK: - Determinism (P3)

    func testDetail_determinism_byteIdenticalTwice() throws {
        for (boss, name) in [("someone-else", "alpha-agent"), ("alpha-agent", "alpha-agent")] {
            let a = try ViewSnapshotHost.snapshotText(of: try detail(boss: boss, agentName: name))
            let b = try ViewSnapshotHost.snapshotText(of: try detail(boss: boss, agentName: name))
            XCTAssertEqual(a, b, "\(name) (boss=\(boss)) must serialize byte-identically twice")
        }
    }

    // MARK: - Unreachable-arm proof (the recorded non-fabrication)

    /// The `showsInspector == true` arm is NOT reachable through the real `@State` seam under
    /// `inspect()`, so the collapsed composite NEVER contains the inspector's bundle/config
    /// path rows. We assert that directly (proving the carve-out is honest, not a silent gap):
    /// the genuine render shows the disclosure chevron pointing RIGHT (collapsed), and the
    /// inspector's monospaced bundle-path `Text` is absent. The expanded arm's panel is covered
    /// by `AgentInspectorPanelPathLeakTests` (C0 SU-3).
    func testDetail_inspectorArm_isCollapsedInTheInitialStateRender() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: try detail(boss: "x", agentName: "alpha-agent"))
        XCTAssertTrue(tree.contains(#"image="chevron.right""#),
                      "the disclosure is collapsed (chevron.right) in the initial state:\n\(tree)")
        XCTAssertFalse(tree.contains("AgentBundles/alpha-agent.ouro/agent.json"),
                       "collapsed: the inspector's config-path row is NOT rendered:\n\(tree)")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The composite's boss-ness flows into the title strip: the boss capsule + the "Boss"
    /// primary action appear only for the boss agent — distinct captured trees.
    func testDetail_negativeControl_bossnessFlipsTree() throws {
        let plain = try ViewSnapshotHost.snapshotText(of: try detail(boss: "x", agentName: "alpha-agent"))
        let boss = try ViewSnapshotHost.snapshotText(of: try detail(boss: "alpha-agent", agentName: "alpha-agent"))
        XCTAssertNotEqual(plain, boss, "the composite's boss-ness must drive the tree")
        XCTAssertTrue(boss.contains(#"text="boss""#), "boss: the title capsule renders:\n\(boss)")
        XCTAssertFalse(plain.contains(#"text="boss""#), "non-boss: no capsule:\n\(plain)")
    }
}
#endif
