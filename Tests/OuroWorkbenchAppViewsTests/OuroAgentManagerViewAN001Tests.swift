#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C0 SU-5 — the **AN-001 + fixed `OuroAgentRecord`** recipe (edge-case playbook #2).
/// `OuroAgentManagerView` branches on `model.ouroAgents.isEmpty` (empty-state text) vs
/// `ForEach(model.ouroAgents)` (a row per agent). The AN-001 source defect: a VM built
/// with the default inventory scans the REAL `~/AgentBundles` in its initializer
/// (`refreshOuroAgents()`), leaking machine-local agent NAMES into `model.ouroAgents` →
/// the rendered tree (a P3 determinism violation). **The recipe pins it twofold:**
///   (1) inject a temp `agentBundlesURL` into BOTH the registrar AND the inventory (a
///       non-existent temp dir → `scan()` returns `[]`) so the init scan is hermetic; and
///   (2) drive `model.ouroAgents = [fixed OuroAgentRecord]` directly (the SU-E3-proven
///       seam) with FIXED names + relative paths so no machine value reaches the tree.
///
/// (The view's `.task { model.refreshOuroAgents() }` does NOT run under ViewInspector's
/// synchronous `inspect()` — so an injected `ouroAgents` survives the snapshot.)
///
/// **Provenance (P2).** `OuroAgentRecord` is a `public` Core value type; constructing it
/// with deterministic inputs IS the real seam (`model.ouroAgents` is the SAME `@Published`
/// the inventory scan populates — direct injection IS the production seam). `model` via the
/// `makeVM` dual-injection store seam.
///
/// **Enumerated state-set (the view's data-driven branch):**
///   - `empty` — `model.ouroAgents == []` (the hermetic temp scan) → the "No Ouro agents…"
///       text + the "no local agents" status line.
///   - `one` — a single fixed non-boss agent → one `OuroAgentRowView` (name + summary, no
///       boss pill).
///   - `many` — two fixed agents, one of which IS the boss → two rows; the boss row carries
///       the "boss" pill; the status line counts both.
@MainActor
final class OuroAgentManagerViewAN001Tests: XCTestCase {

    private func makeVM(bossName: String = "boss") throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c0an001-\(UUID().uuidString)", isDirectory: true)
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

    /// A FIXED record (relative paths; AN-001 hygiene — no machine-local name).
    private func record(name: String) -> OuroAgentRecord {
        OuroAgentRecord(
            name: name,
            bundlePath: "AgentBundles/\(name).ouro",
            configPath: "AgentBundles/\(name).ouro/agent.json",
            status: .ready,
            detail: "ready"
        )
    }

    private func view(boss: String = "boss", agents: [OuroAgentRecord]) throws -> OuroAgentManagerView {
        let model = try makeVM(bossName: boss)
        model.ouroAgents = agents          // the @Published the inventory scan populates
        return OuroAgentManagerView(model: model)
    }

    // MARK: - Enumerated state-set

    func testManager_empty() throws {
        let view = try view(agents: [])
        XCTAssertTrue(view.model.ouroAgents.isEmpty,
                      "provenance: the temp-dir scan is hermetic → no agents")
        XCTAssertEqual(view.model.ouroAgentStatusLine, "no local agents")
        try assertViewSnapshot(of: view, named: "OuroAgentManagerView.empty")
    }

    func testManager_one() throws {
        let view = try view(boss: "someone-else", agents: [record(name: "alpha-agent")])
        XCTAssertEqual(view.model.ouroAgents.count, 1, "provenance: one injected agent")
        try assertViewSnapshot(of: view, named: "OuroAgentManagerView.one")
    }

    func testManager_many_oneIsBoss() throws {
        // Two agents; "boss-agent" matches the boss selection → its row carries the boss pill.
        let view = try view(boss: "boss-agent",
                            agents: [record(name: "alpha-agent"), record(name: "boss-agent")])
        XCTAssertEqual(view.model.ouroAgents.count, 2, "provenance: two injected agents")
        try assertViewSnapshot(of: view, named: "OuroAgentManagerView.many")
    }

    // MARK: - AN-001 hermeticity (P3 — the recipe's whole point)

    /// The hermetic temp `agentBundlesURL` means the init scan leaks NO machine agent name,
    /// and the fixed records carry no machine value → the tree is byte-identical twice and
    /// machine-path-free. (Without the dual-injection, `refreshOuroAgents()` in init would
    /// scan the real `~/AgentBundles`.)
    func testManager_an001Hermetic_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, [OuroAgentRecord])] = [
            ("empty", []),
            ("one", [record(name: "alpha-agent")]),
            ("many", [record(name: "alpha-agent"), record(name: "boss-agent")])
        ]
        for (name, agents) in cases {
            let a = try ViewSnapshotHost.snapshotText(of: try view(boss: "boss-agent", agents: agents))
            let b = try ViewSnapshotHost.snapshotText(of: try view(boss: "boss-agent", agents: agents))
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The `ouroAgents.isEmpty` gate drives the tree (empty-state text vs the agent rows),
    /// and the agent name + boss-match flip what each row renders.
    func testManager_negativeControl_emptyGateAndAgentNamesFlipTree() throws {
        let empty = try ViewSnapshotHost.snapshotText(of: try view(agents: []))
        let one = try ViewSnapshotHost.snapshotText(of: try view(boss: "x", agents: [record(name: "alpha-agent")]))
        let bossRow = try ViewSnapshotHost.snapshotText(of: try view(boss: "alpha-agent", agents: [record(name: "alpha-agent")]))

        XCTAssertNotEqual(empty, one, "the ouroAgents.isEmpty gate must drive the tree")
        XCTAssertTrue(empty.contains("No Ouro agents are installed"), "empty: the empty-state text:\n\(empty)")
        XCTAssertTrue(one.contains(#"text="alpha-agent""#), "one: the agent name renders:\n\(one)")
        XCTAssertFalse(one.contains(#"text="boss""#), "non-boss: no boss pill:\n\(one)")

        XCTAssertNotEqual(one, bossRow, "the boss-match must add the boss pill")
        XCTAssertTrue(bossRow.contains(#"text="boss""#), "boss-match: the boss pill renders:\n\(bossRow)")
    }
}
#endif
