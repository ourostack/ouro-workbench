#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C8 — `AgentHomeEmptyState` (the AN-001 cluster).
///
/// The home empty-state always renders its intro + three gate-free buttons, then a
/// data-driven `if !model.ouroAgents.isEmpty` card: an "Installed agents" launchpad
/// whose `ForEach(model.ouroAgents)` builds a `SidebarAgentRow` per agent, each
/// followed by an OPTIONAL `Text(InstalledAgentRowPresentation.reason(for:detail:))`
/// row — a CAPTURED-node flip driven by the real Core producer (`.ready` → `nil` →
/// no reason; `.disabled`/`.missingConfig`/`.invalidConfig` → a visible reason Text).
///
/// **AN-001 (the cluster's named hazard).** `model.ouroAgents` is the SAME `@Published`
/// the inventory scan populates; a default VM scans the REAL `~/AgentBundles` in its
/// init (`refreshOuroAgents()`), leaking machine-local agent NAMES into the tree (a P3
/// determinism violation — the open backlog defect AN-001). The recipe pins it twofold:
///   (1) inject a temp `agentBundlesURL` into BOTH the registrar AND the inventory (a
///       non-existent temp dir → `scan()` returns `[]`) so the init scan is hermetic; and
///   (2) drive `model.ouroAgents = [fixed OuroAgentRecord]` directly (the SU-E3-proven
///       seam) with FIXED names + relative paths so no machine value reaches the tree.
///
/// **Provenance (P2).** `OuroAgentRecord` is a `public` Core value type; building it with
/// deterministic inputs IS the real seam (direct `@Published` injection is the production
/// seam the live inventory scan also writes). The optional reason Text flows through the
/// real `InstalledAgentRowPresentation.reason(for:detail:)` pure Core producer.
///
/// **Enumerated state-set:**
///   - `empty`        — `ouroAgents == []` → NO "Installed agents" card.
///   - `oneReady`     — a single `.ready` agent → the card + one row, NO reason Text.
///   - `oneNotReady`  — a single `.missingConfig` agent → the card + one row + the reason.
///   - `many`         — two agents (one `.ready`, one `.invalidConfig`) → two rows, one
///                       carrying the invalid-config reason.
@MainActor
final class AgentHomeEmptyStateTests: XCTestCase {

    private func makeVM(bossName: String = "boss") throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c8home-\(UUID().uuidString)", isDirectory: true)
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

    /// A FIXED record (relative paths; AN-001 hygiene — no machine-local name/path).
    private func record(name: String, status: OuroAgentBundleStatus, detail: String = "") -> OuroAgentRecord {
        OuroAgentRecord(
            name: name,
            bundlePath: "AgentBundles/\(name).ouro",
            configPath: "AgentBundles/\(name).ouro/agent.json",
            status: status,
            detail: detail
        )
    }

    private func view(boss: String = "boss", agents: [OuroAgentRecord]) throws -> AgentHomeEmptyState {
        let model = try makeVM(bossName: boss)
        model.ouroAgents = agents          // the @Published the inventory scan populates
        return AgentHomeEmptyState(model: model)
    }

    // MARK: - Enumerated state-set

    func testHome_empty_noInstalledCard() throws {
        let view = try view(agents: [])
        XCTAssertTrue(view.model.ouroAgents.isEmpty,
                      "provenance: the temp-dir scan is hermetic → no agents")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertFalse(tree.contains("Installed agents"),
                       "empty: the !ouroAgents.isEmpty card must NOT render:\n\(tree)")
        try assertViewSnapshot(of: view, named: "AgentHomeEmptyState.empty")
    }

    func testHome_oneReady_cardWithoutReason() throws {
        let view = try view(agents: [record(name: "alpha-agent", status: .ready)])
        XCTAssertEqual(view.model.ouroAgents.count, 1, "provenance: one injected ready agent")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("Installed agents"),
                      "oneReady: the card renders:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="alpha-agent""#),
                      "oneReady: the agent name renders:\n\(tree)")
        XCTAssertNil(InstalledAgentRowPresentation.reason(for: .ready, detail: ""),
                     "provenance: a .ready agent yields no reason → no reason Text")
        try assertViewSnapshot(of: view, named: "AgentHomeEmptyState.oneReady")
    }

    func testHome_oneNotReady_cardWithReason() throws {
        let view = try view(agents: [record(name: "alpha-agent", status: .missingConfig)])
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        // The reason Text flows through the REAL producer.
        let reason = try XCTUnwrap(InstalledAgentRowPresentation.reason(for: .missingConfig, detail: ""))
        XCTAssertTrue(tree.contains(reason),
                      "oneNotReady: the missing-config reason Text renders:\n\(tree)")
        try assertViewSnapshot(of: view, named: "AgentHomeEmptyState.oneNotReady")
    }

    func testHome_many_oneInvalidConfig() throws {
        let view = try view(agents: [
            record(name: "alpha-agent", status: .ready),
            record(name: "beta-agent", status: .invalidConfig, detail: "bad json")
        ])
        XCTAssertEqual(view.model.ouroAgents.count, 2, "provenance: two injected agents")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        let reason = try XCTUnwrap(InstalledAgentRowPresentation.reason(for: .invalidConfig, detail: "bad json"))
        XCTAssertTrue(tree.contains("alpha-agent") && tree.contains("beta-agent"),
                      "many: both agent names render:\n\(tree)")
        XCTAssertTrue(tree.contains(reason),
                      "many: the invalid-config reason renders for the bad agent:\n\(tree)")
        try assertViewSnapshot(of: view, named: "AgentHomeEmptyState.many")
    }

    // MARK: - AN-001 hermeticity (P3 — the cluster's whole point)

    func testHome_an001Hermetic_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, [OuroAgentRecord])] = [
            ("empty", []),
            ("oneReady", [record(name: "alpha-agent", status: .ready)]),
            ("many", [record(name: "alpha-agent", status: .ready),
                      record(name: "beta-agent", status: .invalidConfig, detail: "bad json")])
        ]
        for (name, agents) in cases {
            let a = try ViewSnapshotHost.snapshotText(of: try view(agents: agents))
            let b = try ViewSnapshotHost.snapshotText(of: try view(agents: agents))
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
            XCTAssertFalse(a.contains("/var/folders/"), "\(name): no temp-path leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The `!ouroAgents.isEmpty` gate drives the card, and the agent's status drives the
    /// optional reason Text via the real producer.
    func testHome_negativeControl_cardGateAndReasonFlipTree() throws {
        let empty = try ViewSnapshotHost.snapshotText(of: try view(agents: []))
        let ready = try ViewSnapshotHost.snapshotText(
            of: try view(agents: [record(name: "alpha-agent", status: .ready)]))
        let notReady = try ViewSnapshotHost.snapshotText(
            of: try view(agents: [record(name: "alpha-agent", status: .missingConfig)]))

        XCTAssertNotEqual(empty, ready, "the !ouroAgents.isEmpty gate must drive the card")
        XCTAssertFalse(empty.contains("Installed agents"), "empty: no card:\n\(empty)")
        XCTAssertTrue(ready.contains("Installed agents"), "ready: the card:\n\(ready)")

        XCTAssertNotEqual(ready, notReady,
                          "the status-driven reason Text must change the tree (ready vs not)")
        let reason = try XCTUnwrap(InstalledAgentRowPresentation.reason(for: .missingConfig, detail: ""))
        XCTAssertFalse(ready.contains(reason), "ready: NO reason Text:\n\(ready)")
        XCTAssertTrue(notReady.contains(reason), "notReady: the reason Text renders:\n\(notReady)")
    }
}
#endif
