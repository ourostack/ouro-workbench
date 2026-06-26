#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C7-1 — `OuroAgentRowView` (`:5970`), the agent-manager roster row. The **agent-detail
/// (path-leak) cluster**'s first member: it surfaces the agent's `bundlePath` ONLY through a
/// `.help(...)` tooltip (dropped by the host, AN-004) — so the visible leak vector is the
/// agent NAME + `summaryLine`; AN-001 + the fixed/relative-path discipline keeps both
/// machine-value-free.
///
/// **Data-driven branches (the captured-tree flips):**
///   - `if model.state.boss.agentName == agent.name` → the blue **"boss"** `StatusPill`.
///   - `if let registration` → the MCP `StatusPill` (`BossMCPPillPresentation.label`).
///   - `if registration?.isActionable == true` → the "Connect tools" / "Clean up entry"
///     `Label` button (a captured `Image "link.badge.plus"` + its label text).
///
/// **Provenance (P2).** `model` via the `makeVM` dual-injection store seam (AN-001 temp
/// `agentBundlesURL` into BOTH the registrar AND the inventory → the init scan is hermetic).
/// `agent` is a FIXED `OuroAgentRecord` (relative paths). `registration` is injected through
/// the SAME `@Published bossWorkbenchMCPRegistrationByAgentName` map the live
/// `refreshWorkbenchMCPRegistration()` flow writes (direct injection IS the production seam,
/// the C5/BossDashboard precedent). `liveReadiness` resolves to `.unverified` for a
/// config-`.ready` record with NO injected verdict (never a machine-dependent green).
@MainActor
final class OuroAgentRowViewTests: XCTestCase {

    private func makeVM(bossName: String = "boss") throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c7row-\(UUID().uuidString)", isDirectory: true)
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

    /// A FIXED, RELATIVE-path agent record (the path-leak fix; AN-001 hygiene).
    private func record(name: String) -> OuroAgentRecord {
        OuroAgentRecord(
            name: name,
            bundlePath: "AgentBundles/\(name).ouro",
            configPath: "AgentBundles/\(name).ouro/agent.json",
            status: .ready,
            detail: "ready"
        )
    }

    /// A FIXED registration snapshot (relative config path) at the requested status.
    private func registration(
        for name: String,
        status: BossWorkbenchMCPRegistrationStatus,
        detail: String
    ) -> BossWorkbenchMCPRegistrationSnapshot {
        BossWorkbenchMCPRegistrationSnapshot(
            agentName: name,
            serverName: "ouro_workbench",
            commandPath: "bin/ouro-workbench-mcp",
            agentConfigPath: "AgentBundles/\(name).ouro/agent.json",
            status: status,
            detail: detail
        )
    }

    private func row(
        boss: String = "boss",
        agentName: String,
        registration reg: BossWorkbenchMCPRegistrationSnapshot? = nil
    ) throws -> OuroAgentRowView {
        let model = try makeVM(bossName: boss)
        if let reg {
            model.bossWorkbenchMCPRegistrationByAgentName[agentName] = reg
        }
        return OuroAgentRowView(agent: record(name: agentName), model: model)
    }

    // MARK: - Enumerated state-set

    /// Non-boss, no registration → name + summary line, the "unverified" status pill, NO boss
    /// pill, NO MCP pill, NO Connect button.
    func testRow_plain() throws {
        let view = try row(boss: "someone-else", agentName: "alpha-agent")
        XCTAssertNil(view.model.workbenchMCPRegistration(for: view.agent),
                     "provenance: no registration injected")
        try assertViewSnapshot(of: view, named: "OuroAgentRowView.plain")
    }

    /// The boss-matching row carries the blue "boss" `StatusPill`.
    func testRow_boss() throws {
        let view = try row(boss: "alpha-agent", agentName: "alpha-agent")
        try assertViewSnapshot(of: view, named: "OuroAgentRowView.boss")
    }

    /// A `.registered` registration with NO injection verdict → the MCP pill reads the neutral
    /// "registered (unverified)" (never a machine-dependent green); `.registered` is NOT
    /// actionable → no Connect button.
    func testRow_registeredUnverified() throws {
        let view = try row(boss: "someone-else", agentName: "alpha-agent",
                           registration: registration(for: "alpha-agent", status: .registered, detail: "registered"))
        XCTAssertEqual(view.model.workbenchMCPRegistration(for: view.agent)?.isActionable, false,
                       "provenance: .registered is not actionable")
        try assertViewSnapshot(of: view, named: "OuroAgentRowView.registeredUnverified")
    }

    /// A `.notRegistered` registration is ACTIONABLE → the MCP pill reads "not registered" AND
    /// the "Connect tools" button appears (`Image "link.badge.plus"`).
    func testRow_notRegisteredActionable() throws {
        let view = try row(boss: "someone-else", agentName: "alpha-agent",
                           registration: registration(for: "alpha-agent", status: .notRegistered, detail: "not registered"))
        XCTAssertEqual(view.model.workbenchMCPRegistration(for: view.agent)?.isActionable, true,
                       "provenance: .notRegistered is actionable")
        try assertViewSnapshot(of: view, named: "OuroAgentRowView.notRegisteredActionable")
    }

    /// A `.needsUpdate` registration is ALSO actionable (a stale Workbench entry to clean), but
    /// the action button's title flips to "Clean up entry" (vs the `.notRegistered` "Connect
    /// tools"). Without this state the
    /// `registration?.status == .needsUpdate ? "Clean up entry" : "Connect tools"` ternary's
    /// true arm is rendered-but-never-asserted (a vacuous secondary guard).
    func testRow_needsUpdateActionable() throws {
        let view = try row(boss: "someone-else", agentName: "alpha-agent",
                           registration: registration(for: "alpha-agent", status: .needsUpdate, detail: "stale entry"))
        XCTAssertEqual(view.model.workbenchMCPRegistration(for: view.agent)?.isActionable, true,
                       "provenance: .needsUpdate is actionable")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="Clean up entry""#),
                      "the needsUpdate arm renders the clean-up button title:\n\(tree)")
        XCTAssertFalse(tree.contains(#"text="Connect tools""#),
                       "the needsUpdate arm must NOT render the notRegistered title:\n\(tree)")
        try assertViewSnapshot(of: view, named: "OuroAgentRowView.needsUpdateActionable")
    }

    // MARK: - Path-leak + AN-001 determinism (P3)

    /// The `.help(agent.bundlePath)` tooltip is the ONLY path vector and the host drops it
    /// (AN-004). Defended directly: NO machine path reaches the tree, byte-identical twice.
    func testRow_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, BossWorkbenchMCPRegistrationSnapshot?)] = [
            ("plain", nil),
            ("registered", registration(for: "alpha-agent", status: .registered, detail: "registered")),
            ("actionable", registration(for: "alpha-agent", status: .notRegistered, detail: "not registered"))
        ]
        for (label, reg) in cases {
            let a = try ViewSnapshotHost.snapshotText(of: try row(boss: "someone-else", agentName: "alpha-agent", registration: reg))
            let b = try ViewSnapshotHost.snapshotText(of: try row(boss: "someone-else", agentName: "alpha-agent", registration: reg))
            XCTAssertEqual(a, b, "\(label) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(label): no /Users/ leak:\n\(a)")
            XCTAssertFalse(a.contains("/var/folders/"), "\(label): no temp-dir leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The three data-driven branches each flip the captured tree: the boss match adds the
    /// "boss" pill; an injected registration adds the MCP pill; an actionable registration
    /// adds the Connect button. Distinct trees prove each branch is load-bearing.
    func testRow_negativeControl_branchesFlipTree() throws {
        let plain = try ViewSnapshotHost.snapshotText(of: try row(boss: "x", agentName: "alpha-agent"))
        let boss = try ViewSnapshotHost.snapshotText(of: try row(boss: "alpha-agent", agentName: "alpha-agent"))
        let registered = try ViewSnapshotHost.snapshotText(of: try row(boss: "x", agentName: "alpha-agent",
            registration: registration(for: "alpha-agent", status: .registered, detail: "registered")))
        let actionable = try ViewSnapshotHost.snapshotText(of: try row(boss: "x", agentName: "alpha-agent",
            registration: registration(for: "alpha-agent", status: .notRegistered, detail: "not registered")))

        XCTAssertNotEqual(plain, boss, "the boss match must add the boss pill")
        XCTAssertFalse(plain.contains(#"text="boss""#), "non-boss: no boss pill:\n\(plain)")
        XCTAssertTrue(boss.contains(#"text="boss""#), "boss-match: the boss pill renders:\n\(boss)")

        XCTAssertNotEqual(plain, registered, "an injected registration must add the MCP pill")
        XCTAssertTrue(registered.contains("registered (unverified)"), "registered: the unverified MCP pill:\n\(registered)")

        XCTAssertNotEqual(registered, actionable, "an actionable registration must add the Connect button")
        XCTAssertTrue(actionable.contains(#"text="not registered""#), "actionable: the not-registered pill:\n\(actionable)")
        XCTAssertTrue(actionable.contains(#"image="link.badge.plus""#), "actionable: the Connect button glyph:\n\(actionable)")
        XCTAssertFalse(registered.contains(#"image="link.badge.plus""#), "registered: no Connect button:\n\(registered)")
    }
}
#endif
