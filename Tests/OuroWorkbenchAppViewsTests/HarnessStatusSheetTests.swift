#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C11-3 — `HarnessStatusSheet` (the high-fan-out harness diagnostic sheet).
///
/// The consolidated daemon / agents / boss-reachability view. Its whole tree is
/// derived through the REAL `HarnessStatusBuilder.build` (the pure Core producer)
/// off the SAME `@Published` inputs the live `refreshHarnessStatus()` writes:
///   - `model.bossDashboard`  → the daemon section + the `observedAt` footer;
///   - `model.ouroAgents`     → the "Local agents" `ForEach` (AN-001 hermetic);
///   - `model.bossWorkbenchMCPRegistration` / `…ByAgentName` / `…ToolsInjection…`
///                            → the boss-reachability + per-agent MCP pills.
/// Driving those `@Published`s directly IS the production seam (the AN-001 /
/// BossDashboard / C7 precedent: the live refresh paths set the exact same vars).
/// The `HarnessStatus` itself is NEVER hand-assembled — it flows through the real
/// builder via `model.harnessStatus`.
///
/// **AN-001 (hermetic).** The default VM scans the real `~/AgentBundles` in init,
/// leaking machine-local agent names. Pinned by the C8 dual-injection: a temp
/// `agentBundlesURL` into BOTH the registrar AND the inventory (a non-existent temp
/// dir → `scan()` == `[]`), then `model.ouroAgents = [fixed record]`.
///
/// **Clock / `observedAt` (the cluster's named hazard) — handled + cross-TZ proven.**
/// `status.observedAt` is `dashboard.observedAt`: a PRE-FORMATTED `String?` copied
/// VERBATIM from `/api/machine` (NOT a `Date` re-formatted at read time), rendered
/// as `Text("Daemon observed at \(observedAt)")`. So there is no `Date`/FormatStyle
/// to thread through `Date.workbenchTimeText` — the determinism fix is simply a
/// FIXED string literal in the fixture (no `Date()`/`.now`/machine clock). The
/// `withObservedAt` test still proves the rendered footer is byte-identical across
/// `TZ ∈ {America/Los_Angeles, America/New_York, UTC}` (a verbatim string is
/// inherently zone-independent — proven, not asserted) so a PDT-recorded ref can
/// never mismatch a UTC runner. The `nilDashboard` state proves the `if let
/// observedAt` ABSENT arm (no footer).
///
/// **Enumerated state-set (the captured-tree gates):**
///   - `healthy`        — daemon running + boss reachable + a confirmed-ready agent
///                        → overall "healthy"; no urgent action rows; observedAt set.
///   - `daemonDown`     — machine read failed → daemon unreachable → overall
///                        "blocked"; the urgent "Bring Back Online" action row.
///   - `bossUnreachable`— daemon up, boss MCP `.notRegistered` → overall "blocked";
///                        the urgent register-MCP action row + the mcp-status text.
///   - `agentsEmpty`    — no agents → the "No Ouro agents…" empty Text.
///   - `withActionResult` — a `harnessActionResult` set → the result banner renders.
///   - `nilDashboard`   — `bossDashboard == nil` → "not checked yet" + NO observedAt.
@MainActor
final class HarnessStatusSheetTests: XCTestCase {

    /// A fixed ISO-8601 string — NOT a `Date` (the surface renders it verbatim), so
    /// the rendered footer is byte-stable and zone-independent.
    private static let fixedObservedAt = "2026-01-01T00:00:00Z"

    private func makeVM(bossName: String = "alpha-boss") throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c11harness-\(UUID().uuidString)", isDirectory: true)
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

    private func record(name: String, status: OuroAgentBundleStatus = .ready, detail: String = "configured")
        -> OuroAgentRecord {
        OuroAgentRecord(
            name: name,
            bundlePath: "AgentBundles/\(name).ouro",
            configPath: "AgentBundles/\(name).ouro/agent.json",
            status: status,
            detail: detail
        )
    }

    private func dashboard(
        bossName: String,
        daemonStatus: String,
        machineAvailable: Bool = true,
        observedAt: String? = fixedObservedAt
    ) -> BossDashboardSnapshot {
        BossDashboardSnapshot(
            agentName: bossName,
            daemonStatus: daemonStatus,
            daemonMode: "managed",
            daemonVersion: "alpha.700",
            attentionLabel: "All quiet",
            openObligations: 0,
            activeCodingAgents: 0,
            blockedCodingAgents: 0,
            needsMeItems: [],
            codingItems: [],
            observedAt: observedAt,
            availability: machineAvailable ? .complete
                : BossDashboardAvailability(
                    machineAvailable: false,
                    needsMeAvailable: false,
                    codingAvailable: false,
                    issues: ["machine: connection refused"])
        )
    }

    private func reg(_ status: BossWorkbenchMCPRegistrationStatus, detail: String = "")
        -> BossWorkbenchMCPRegistrationSnapshot {
        BossWorkbenchMCPRegistrationSnapshot(
            agentName: "alpha-boss",
            serverName: "workbench",
            commandPath: "AgentBundles/workbench-mcp",   // fixed/relative — never rendered, kept hermetic anyway
            agentConfigPath: "AgentBundles/alpha-boss.ouro/agent.json",
            status: status,
            detail: detail
        )
    }

    // MARK: - Enumerated state-set

    func testSheet_healthy_overallHealthyNoUrgentAction() throws {
        let model = try makeVM()
        model.ouroAgents = [record(name: "alpha-boss")]
        model.bossDashboard = dashboard(bossName: "alpha-boss", daemonStatus: "running")
        model.bossWorkbenchMCPRegistration = reg(.registered)
        model.bossWorkbenchMCPRegistrationByAgentName = ["alpha-boss": reg(.registered)]
        model.bossWorkbenchToolsInjectionByAgentName = ["alpha-boss": .confirmed(.present)]
        model.agentOutwardVerdicts = ["alpha-boss": .working]

        let status = model.harnessStatus
        XCTAssertEqual(status.overallState, .healthy,
                       "provenance: the real builder yields healthy for a reachable daemon+boss")
        let view = HarnessStatusSheet(model: model)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("Harness Status"), "the title:\n\(tree)")
        // The overall pill renders `status.overallState.displayName` ("healthy"); the
        // `displayName` extension is fileprivate to the views module, so we assert the
        // literal the pill shows (kept in sync via the recorded reference + mutation).
        XCTAssertTrue(tree.contains(#"text="healthy""#), "the overall pill:\n\(tree)")
        // Repair-daemon is ALWAYS available (restarting a running daemon is harmless),
        // so its row renders even when healthy — but NOT urgently, and the register-MCP
        // row (only offered for an actionable boss) is absent in the healthy state.
        XCTAssertFalse(status.controlOffer.isUrgent(.repairDaemon),
                       "healthy: repair is available but not urgent")
        XCTAssertFalse(status.controlOffer.isAvailable(.registerWorkbenchMCP),
                       "healthy: a registered boss → no register-MCP action")
        XCTAssertFalse(tree.contains("Connect Workbench tools"),
                       "healthy: the register-MCP action row must be absent:\n\(tree)")
        try assertViewSnapshot(of: view, named: "HarnessStatusSheet.healthy")
    }

    func testSheet_daemonDown_blockedWithRepairAction() throws {
        let model = try makeVM()
        model.ouroAgents = [record(name: "alpha-boss")]
        model.bossDashboard = dashboard(bossName: "alpha-boss", daemonStatus: "unknown", machineAvailable: false)
        model.bossWorkbenchMCPRegistration = reg(.registered)

        let status = model.harnessStatus
        XCTAssertEqual(status.overallState, .blocked,
                       "provenance: a failed machine read → daemon unreachable → blocked")
        XCTAssertTrue(status.controlOffer.isUrgent(.repairDaemon),
                      "provenance: an unreachable daemon makes repair urgent")
        let view = HarnessStatusSheet(model: model)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="blocked""#), "blocked pill:\n\(tree)")
        XCTAssertTrue(tree.contains("Bring Back Online"), "the urgent repair action row:\n\(tree)")
        XCTAssertTrue(tree.contains("connection refused"),
                      "the daemon unreachable reason surfaces (via the real builder):\n\(tree)")
        try assertViewSnapshot(of: view, named: "HarnessStatusSheet.daemonDown")
    }

    func testSheet_bossUnreachable_registerMCPAction() throws {
        let model = try makeVM()
        model.ouroAgents = [record(name: "alpha-boss")]
        model.bossDashboard = dashboard(bossName: "alpha-boss", daemonStatus: "running")
        model.bossWorkbenchMCPRegistration = reg(.notRegistered, detail: "tools binary not found")
        model.bossWorkbenchMCPRegistrationByAgentName = ["alpha-boss": reg(.notRegistered)]
        model.agentOutwardVerdicts = ["alpha-boss": .working]

        let status = model.harnessStatus
        XCTAssertEqual(status.overallState, .blocked,
                       "provenance: an unregistered boss MCP → boss unreachable → blocked")
        XCTAssertTrue(status.controlOffer.isAvailable(.registerWorkbenchMCP),
                      "provenance: a notRegistered boss makes register-MCP actionable")
        let view = HarnessStatusSheet(model: model)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("Connect Workbench tools"), "the urgent register action row:\n\(tree)")
        XCTAssertTrue(tree.contains("tools binary missing"),
                      "the unregistered mcp-status text (via the real builder):\n\(tree)")
        try assertViewSnapshot(of: view, named: "HarnessStatusSheet.bossUnreachable")
    }

    func testSheet_agentsEmpty_emptyCopy() throws {
        let model = try makeVM()
        model.ouroAgents = []
        model.bossDashboard = dashboard(bossName: "alpha-boss", daemonStatus: "running")
        model.bossWorkbenchMCPRegistration = reg(.registered)

        let view = HarnessStatusSheet(model: model)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("No Ouro agents are installed on this machine yet"),
                      "the empty-agents copy:\n\(tree)")
        try assertViewSnapshot(of: view, named: "HarnessStatusSheet.agentsEmpty")
    }

    func testSheet_withActionResult_banner() throws {
        let model = try makeVM()
        model.ouroAgents = [record(name: "alpha-boss")]
        model.bossDashboard = dashboard(bossName: "alpha-boss", daemonStatus: "running")
        model.bossWorkbenchMCPRegistration = reg(.registered)
        model.harnessActionResult = HarnessActionResult(
            kind: .repairDaemon, succeeded: true, message: "Brought your agent back online.")

        let view = HarnessStatusSheet(model: model)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("checkmark.circle.fill"),
                      "the embedded HarnessActionResultBanner renders the success symbol:\n\(tree)")
        XCTAssertTrue(tree.contains("Brought your agent back online."), "the banner message:\n\(tree)")
        try assertViewSnapshot(of: view, named: "HarnessStatusSheet.withActionResult")
    }

    func testSheet_nilDashboard_noObservedAtFooter() throws {
        let model = try makeVM()
        model.ouroAgents = [record(name: "alpha-boss")]
        model.bossDashboard = nil   // never refreshed
        model.bossWorkbenchMCPRegistration = reg(.registered)

        let status = model.harnessStatus
        XCTAssertNil(status.observedAt, "provenance: no dashboard → no observedAt")
        let view = HarnessStatusSheet(model: model)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertFalse(tree.contains("Daemon observed at"),
                       "nilDashboard: the `if let observedAt` footer must be ABSENT:\n\(tree)")
        XCTAssertTrue(tree.contains("not checked yet"),
                      "the daemon 'not checked yet' status (via the real builder):\n\(tree)")
        try assertViewSnapshot(of: view, named: "HarnessStatusSheet.nilDashboard")
    }

    // MARK: - Clock / observedAt determinism (the cluster's named hazard)

    /// The `observedAt` footer renders a FIXED verbatim ISO-8601 string. It is NOT a
    /// `Date` re-formatted at read time, so the rendered footer is byte-identical
    /// regardless of the runner's TimeZone (proven across PST / EST / UTC). A
    /// PDT-recorded reference can never mismatch a UTC runner.
    func testSheet_observedAtFooter_byteIdenticalAcrossTimeZones() throws {
        func footerTree() throws -> String {
            let model = try makeVM()
            model.ouroAgents = [record(name: "alpha-boss")]
            model.bossDashboard = dashboard(bossName: "alpha-boss", daemonStatus: "running")
            model.bossWorkbenchMCPRegistration = reg(.registered)
            return try ViewSnapshotHost.snapshotText(of: HarnessStatusSheet(model: model))
        }
        let original = getenv("TZ").map { String(cString: $0) }
        defer {
            if let original { setenv("TZ", original, 1) } else { unsetenv("TZ") }
            tzset()
        }
        var rendered: [String] = []
        for tz in ["America/Los_Angeles", "America/New_York", "UTC"] {
            setenv("TZ", tz, 1); tzset()
            let tree = try footerTree()
            XCTAssertTrue(tree.contains("Daemon observed at \(Self.fixedObservedAt)"),
                          "the fixed observedAt footer renders under TZ=\(tz):\n\(tree)")
            rendered.append(tree)
        }
        XCTAssertEqual(Set(rendered).count, 1,
                       "the rendered tree must be byte-identical across all three TimeZones")
    }

    func testSheet_deterministic_byteIdenticalTwiceAndNoLeak() throws {
        func tree() throws -> String {
            let model = try makeVM()
            model.ouroAgents = [record(name: "alpha-boss")]
            model.bossDashboard = dashboard(bossName: "alpha-boss", daemonStatus: "running")
            model.bossWorkbenchMCPRegistration = reg(.registered)
            return try ViewSnapshotHost.snapshotText(of: HarnessStatusSheet(model: model))
        }
        let a = try tree(); let b = try tree()
        XCTAssertEqual(a, b, "the sheet must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
        XCTAssertFalse(a.contains("/var/folders/"), "no temp-path leak (AN-001 hermetic):\n\(a)")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The `if let observedAt` footer is a real captured-node gate: the healthy state
    /// (observedAt set) renders it; the nilDashboard state (no observedAt) drops it.
    func testSheet_negativeControl_observedAtFooterGate() throws {
        let withModel = try makeVM()
        withModel.ouroAgents = [record(name: "alpha-boss")]
        withModel.bossDashboard = dashboard(bossName: "alpha-boss", daemonStatus: "running")
        withModel.bossWorkbenchMCPRegistration = reg(.registered)
        let withFooter = try ViewSnapshotHost.snapshotText(of: HarnessStatusSheet(model: withModel))

        let withoutModel = try makeVM()
        withoutModel.ouroAgents = [record(name: "alpha-boss")]
        withoutModel.bossDashboard = nil
        withoutModel.bossWorkbenchMCPRegistration = reg(.registered)
        let withoutFooter = try ViewSnapshotHost.snapshotText(of: HarnessStatusSheet(model: withoutModel))

        XCTAssertNotEqual(withFooter, withoutFooter, "the observedAt footer must flip the tree")
        XCTAssertTrue(withFooter.contains("Daemon observed at"))
        XCTAssertFalse(withoutFooter.contains("Daemon observed at"))
    }
}
#endif
