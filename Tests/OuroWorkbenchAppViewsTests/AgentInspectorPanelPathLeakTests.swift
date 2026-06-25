#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C0 SU-3 — the **path-leak (hard)** recipe (edge-case playbook #3). `AgentInspectorPanel`
/// renders `Text(agent.bundlePath)` (`:8181`) and `Text(agent.configPath)` (`:8192`) as
/// VISIBLE, selectable content. The host's whitelist can NOT strip a content `Text` (unlike
/// the `.help` tooltip drop, AN-004) — so a record built from a real on-disk scan
/// (`OuroAgentInventory.scan` always sets `bundlePath: bundleURL.path`, an absolute machine
/// path) would leak `/Users/<name>/…` or a `/var/folders/<random>/…` temp path into the
/// committed reference (a P3 violation). **The FIXTURE is the only fix:** build the
/// `OuroAgentRecord` with FIXED, RELATIVE paths so no machine path reaches the tree, defended
/// by `!tree.contains("/Users/")`.
///
/// **Provenance (P2).** `OuroAgentRecord` is a `public` Core value type; constructing it with
/// deterministic relative paths IS the real seam (the same way the sidebar test builds a real
/// `ProcessEntry` and the chip test parses a real `GitSessionStatus` — P2 forbids
/// hand-assembling serializer OUTPUT / model STATE, not instantiating a real model VALUE with
/// deterministic inputs). The panel's `model` is provenance-built via the `makeVM`
/// dual-injection store seam (AN-001 temp `agentBundlesURL`). The optional `registration`
/// (the panel's one data-driven branch, `if let registration`) is a real
/// `BossWorkbenchMCPRegistrationSnapshot` value.
///
/// **Access-widening (SU-E precedent):** `AgentInspectorPanel` was `private struct` →
/// widened to `internal` (visibility-only, zero behavior) so `@testable import` can reach it.
///
/// **Enumerated state-set (the panel's data-driven branch):**
///   - `noRegistration` — `registration == nil` → bundle/config/detail rows only.
///   - `withRegistration` — `registration != nil` → the extra `MCP: <detail>` row.
@MainActor
final class AgentInspectorPanelPathLeakTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c0inspect-\(UUID().uuidString)", isDirectory: true)
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

    /// A FIXED, RELATIVE-path agent record — the path-leak fix. No `/Users/…`, no
    /// `/var/folders/<random>/…`, no machine-local component.
    private func record() -> OuroAgentRecord {
        OuroAgentRecord(
            name: "fixture-agent",
            bundlePath: "AgentBundles/fixture-agent.ouro",
            configPath: "AgentBundles/fixture-agent.ouro/agent.json",
            status: .ready,
            detail: "ready"
        )
    }

    private func registration() -> BossWorkbenchMCPRegistrationSnapshot {
        BossWorkbenchMCPRegistrationSnapshot(
            agentName: "fixture-agent",
            serverName: "ouro_workbench",
            commandPath: "bin/ouro-workbench-mcp",
            agentConfigPath: "AgentBundles/fixture-agent.ouro/agent.json",
            status: .registered,
            detail: "registered"
        )
    }

    private func panel(registration: BossWorkbenchMCPRegistrationSnapshot?) throws -> AgentInspectorPanel {
        AgentInspectorPanel(agent: record(), model: try makeVM(), registration: registration)
    }

    // MARK: - Enumerated state-set

    func testPanel_noRegistration() throws {
        let view = try panel(registration: nil)
        XCTAssertEqual(view.agent.bundlePath, "AgentBundles/fixture-agent.ouro",
                       "provenance: fixed relative bundle path")
        try assertViewSnapshot(of: view, named: "AgentInspectorPanel.noRegistration")
    }

    func testPanel_withRegistration() throws {
        let view = try panel(registration: registration())
        try assertViewSnapshot(of: view, named: "AgentInspectorPanel.withRegistration")
    }

    // MARK: - Path-leak defense (P3 — the recipe's whole point)

    /// The committed references render the agent's bundle/config paths VERBATIM, so the
    /// fixture's fixed/relative paths are the ONLY thing keeping a machine path out of the
    /// tree. Assert it directly: the rendered tree contains the relative paths and NO
    /// `/Users/` (nor a `/var/folders/` temp leak).
    func testPanel_pathLeakDefense_noMachinePathInTree() throws {
        for reg in [nil, registration()] as [BossWorkbenchMCPRegistrationSnapshot?] {
            let tree = try ViewSnapshotHost.snapshotText(of: try panel(registration: reg))
            XCTAssertTrue(tree.contains("AgentBundles/fixture-agent.ouro"),
                          "the bundle path renders verbatim (the leak vector):\n\(tree)")
            XCTAssertFalse(tree.contains("/Users/"), "no /Users/ machine-path leak:\n\(tree)")
            XCTAssertFalse(tree.contains("/var/folders/"), "no temp-dir path leak:\n\(tree)")
        }
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The `if let registration` branch drives the tree (the MCP row appears only with a
    /// registration), and the agent's paths render verbatim (changing them changes the tree).
    func testPanel_negativeControl_registrationBranchAndPathsFlipTree() throws {
        let without = try ViewSnapshotHost.snapshotText(of: try panel(registration: nil))
        let with = try ViewSnapshotHost.snapshotText(of: try panel(registration: registration()))
        XCTAssertNotEqual(without, with, "the registration branch must drive the tree")
        XCTAssertFalse(without.contains("MCP:"), "no registration: no MCP row:\n\(without)")
        XCTAssertTrue(with.contains("MCP: registered"), "registration: MCP row:\n\(with)")

        // A different bundle path must change the rendered tree (the paths are load-bearing
        // content, not a constant) — the proof the leak vector is real.
        let alt = AgentInspectorPanel(
            agent: OuroAgentRecord(name: "fixture-agent", bundlePath: "Other/path.ouro",
                                   configPath: "Other/path.ouro/agent.json", status: .ready, detail: "ready"),
            model: try makeVM(), registration: nil)
        let altTree = try ViewSnapshotHost.snapshotText(of: alt)
        XCTAssertNotEqual(without, altTree, "the rendered bundle/config paths must drive the tree")
        XCTAssertTrue(altTree.contains("Other/path.ouro"), altTree)
    }

    // MARK: - Determinism (P3)

    func testPanel_determinism_byteIdenticalTwiceAndNoLeak() throws {
        for reg in [nil, registration()] as [BossWorkbenchMCPRegistrationSnapshot?] {
            let a = try ViewSnapshotHost.snapshotText(of: try panel(registration: reg))
            let b = try ViewSnapshotHost.snapshotText(of: try panel(registration: reg))
            XCTAssertEqual(a, b, "must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
        }
    }
}
#endif
