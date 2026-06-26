#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C7-3 — `AgentStatusCard` (`:8304`), the agent-detail pane's prominent status card. The
/// agent-detail (path-leak) cluster: it renders `Text(agent.detail)` (a fixed model string,
/// no path) — the captured leak surface is the agent's `detail`, kept machine-value-free by
/// the FIXED `OuroAgentRecord`.
///
/// **Data-driven branches (the captured-tree flips):**
///   - `statusHeadline`/`statusIcon`/the readiness pill route through
///     `InstalledAgentRowPresentation` off the LIVE readiness — `.unverified` (config-`.ready`
///     with NO live verdict; the deterministic, NEVER-machine-green default) vs `.ready` (an
///     injected `.working` outward verdict → "Bundle ready" + `checkmark.seal.fill`).
///   - `if let registration, registration.isActionable` → the "Connect Workbench tools" button
///     (`Image "link.badge.plus"`).
///   - `if let registration` → the `mcp <label>` pill (`BossMCPPillPresentation.label`).
///   - `if !agent.isUsableAsBoss` → the "boss blocked" pill (a `.missingConfig` record).
///
/// **Provenance (P2).** `model` via the `makeVM` dual-injection store seam (AN-001). `agent`
/// is a FIXED `OuroAgentRecord` (relative paths). The live verdict is injected through the
/// SAME `@Published agentOutwardVerdicts` map the live check writes (direct injection IS the
/// production seam). `registration` is a fixed snapshot value.
///
/// **Access-widening (C7-3, SU-E precedent):** `AgentStatusCard` was `private struct` →
/// widened to `internal`. Zero behavior change.
@MainActor
final class AgentStatusCardTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c7card-\(UUID().uuidString)", isDirectory: true)
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

    private func record(
        name: String = "alpha-agent",
        status: OuroAgentBundleStatus = .ready,
        detail: String = "ready"
    ) -> OuroAgentRecord {
        OuroAgentRecord(
            name: name,
            bundlePath: "AgentBundles/\(name).ouro",
            configPath: "AgentBundles/\(name).ouro/agent.json",
            status: status,
            detail: detail
        )
    }

    private func registration(status: BossWorkbenchMCPRegistrationStatus, detail: String) -> BossWorkbenchMCPRegistrationSnapshot {
        BossWorkbenchMCPRegistrationSnapshot(
            agentName: "alpha-agent",
            serverName: "ouro_workbench",
            commandPath: "bin/ouro-workbench-mcp",
            agentConfigPath: "AgentBundles/alpha-agent.ouro/agent.json",
            status: status,
            detail: detail
        )
    }

    private func card(
        agent: OuroAgentRecord,
        verdict: ProviderConnectionVerdict? = nil,
        registration reg: BossWorkbenchMCPRegistrationSnapshot? = nil
    ) throws -> AgentStatusCard {
        let model = try makeVM()
        if let verdict {
            model.agentOutwardVerdicts[agent.name] = verdict
        }
        return AgentStatusCard(agent: agent, model: model, registration: reg)
    }

    // MARK: - Enumerated state-set

    /// Config-`.ready`, NO live verdict → the honest `.unverified` headline "Not verified yet"
    /// (NEVER the machine-dependent green), no registration, usable as boss.
    func testCard_unverified() throws {
        let view = try card(agent: record())
        try assertViewSnapshot(of: view, named: "AgentStatusCard.unverified")
    }

    /// An injected `.working` outward verdict → the `.ready` headline "Bundle ready" +
    /// `checkmark.seal.fill` + the "ready" pill.
    func testCard_ready() throws {
        let view = try card(agent: record(), verdict: .working)
        try assertViewSnapshot(of: view, named: "AgentStatusCard.ready")
    }

    /// An actionable (`.notRegistered`) registration → the "Connect Workbench tools" button +
    /// the "mcp not registered" pill.
    func testCard_actionableRegistration() throws {
        let view = try card(agent: record(),
                            registration: registration(status: .notRegistered, detail: "not registered"))
        XCTAssertEqual(view.registration?.isActionable, true, "provenance: .notRegistered is actionable")
        try assertViewSnapshot(of: view, named: "AgentStatusCard.actionableRegistration")
    }

    /// A `.missingConfig` record is NOT usable as boss → the "boss blocked" pill; the headline
    /// reads the config truth "Bundle missing agent.json".
    func testCard_bossBlocked() throws {
        let view = try card(agent: record(status: .missingConfig, detail: "agent.json missing"))
        XCTAssertFalse(view.agent.isUsableAsBoss, "provenance: missingConfig → not usable as boss")
        try assertViewSnapshot(of: view, named: "AgentStatusCard.bossBlocked")
    }

    // MARK: - Determinism (P3)

    func testCard_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, OuroAgentRecord, ProviderConnectionVerdict?, BossWorkbenchMCPRegistrationSnapshot?)] = [
            ("unverified", record(), nil, nil),
            ("ready", record(), .working, nil),
            ("actionable", record(), nil, registration(status: .notRegistered, detail: "not registered")),
            ("blocked", record(status: .missingConfig, detail: "agent.json missing"), nil, nil)
        ]
        for (label, agent, verdict, reg) in cases {
            let a = try ViewSnapshotHost.snapshotText(of: try card(agent: agent, verdict: verdict, registration: reg))
            let b = try ViewSnapshotHost.snapshotText(of: try card(agent: agent, verdict: verdict, registration: reg))
            XCTAssertEqual(a, b, "\(label) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(label): no /Users/ leak:\n\(a)")
            XCTAssertFalse(a.contains("/var/folders/"), "\(label): no temp-dir leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The live-readiness branch flips the headline ("Not verified yet" → "Bundle ready"), an
    /// actionable registration adds the Connect button + mcp pill, and a non-usable record adds
    /// the "boss blocked" pill — each a distinct captured tree.
    func testCard_negativeControl_branchesFlipTree() throws {
        let unverified = try ViewSnapshotHost.snapshotText(of: try card(agent: record()))
        let ready = try ViewSnapshotHost.snapshotText(of: try card(agent: record(), verdict: .working))
        let actionable = try ViewSnapshotHost.snapshotText(of: try card(agent: record(),
            registration: registration(status: .notRegistered, detail: "not registered")))
        let blocked = try ViewSnapshotHost.snapshotText(of: try card(agent: record(status: .missingConfig, detail: "agent.json missing")))

        XCTAssertNotEqual(unverified, ready, "the live verdict must flip the headline")
        XCTAssertTrue(unverified.contains("Not verified yet"), "unverified headline:\n\(unverified)")
        XCTAssertTrue(ready.contains("Bundle ready"), "ready headline:\n\(ready)")
        XCTAssertTrue(ready.contains(#"image="checkmark.seal.fill""#), "ready: the success seal:\n\(ready)")

        XCTAssertNotEqual(unverified, actionable, "an actionable registration must add the Connect button")
        XCTAssertTrue(actionable.contains(#"image="link.badge.plus""#), "actionable: the Connect button:\n\(actionable)")
        XCTAssertTrue(actionable.contains("mcp not registered"), "actionable: the mcp pill:\n\(actionable)")

        XCTAssertNotEqual(unverified, blocked, "a non-usable record must add the boss-blocked pill")
        XCTAssertTrue(blocked.contains(#"text="boss blocked""#), "blocked: the pill:\n\(blocked)")
        XCTAssertFalse(unverified.contains(#"text="boss blocked""#), "usable: no boss-blocked pill:\n\(unverified)")
    }
}
#endif
