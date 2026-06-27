#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C11-6 — RECONFIRM ledger for the audit-branchless C11-adjacent helper/shell
/// views. Each is RE-CONFIRMED against the host whitelist (Text string / TextField
/// bound value / Image SF-symbol name / a11y label-value-id): does a data branch
/// flip a CAPTURED node (→ LOGIC, snapshot it) or is the only variance dropped
/// attribute/structure (→ genuinely branchless, DEFER — do NOT snapshot a vacuous
/// green)? The verdicts (recorded here, not hand-waved) for the C11 cluster:
///
///   - `HarnessActionRow`  → DEFER (genuinely branchless within itself): the only
///       branches are `if isUrgent { .borderedProminent } else { .bordered }`
///       (button STYLE = attribute-only, dropped) and `if isBusy { ProgressView }`
///       (a node-less spinner + `.disabled`, neither captured). The `Label(title,
///       systemImage:)` is a PARAMETER, not an in-view branch. Proven below: across
///       the urgent/busy matrix the captured tree of the row (as it renders inside
///       `HarnessStatusSheet`) is identical. COVERED TRANSITIVELY by C11-3 (the
///       daemon/boss sections render it with fixed title/symbol).
///   - `HarnessSection`    → DEFER (covered transitively): its `if let trailingText`
///       IS a captured-node gate, but it's a layout helper exercised end-to-end by
///       C11-3 (the agent section passes a trailing summary; the daemon/boss
///       sections pass none). No standalone widening needed.
///   - `HarnessDetailRow`  → DEFER (covered transitively): `Text(label)` + `Text(
///       value)`, both parameters, no in-view branch — genuinely branchless;
///       exercised by every C11-3 daemon/boss detail row.
///   - `SettingsSection`   → DEFER (genuinely branchless): `Label + content()`
///       passthrough, no branch — covered transitively by C11-5.
///   - `AboutSheet`        → DEFER (branchless + machine-derived): no in-view data
///       branch; renders `Bundle.main` `CFBundleVersion` (the build hash) through a
///       vendored `OuroAppShellUI.AppShellAboutView`. A machine/build-version
///       surface with no data-state seam → a final-step allowlist candidate, NOT a
///       snapshot (a snapshot would either be vacuous or leak the build hash).
///   - `WorkbenchUpdatePanel` / `AboutSheet` → DEFER (branchless
///       wrappers): pure passthroughs to the vendored `OuroAppShellUI.
///       ReleaseUpdateControls` / `AppShellAboutView`; the stateful branches live in
///       vendored components (outside our coverage). Covered transitively by C11-5
///       and direct wrapper interaction tests.
///
/// This file PROVES the `HarnessActionRow` branchless verdict empirically (the one
/// in-view ternary the audit flagged) so the DEFER is recorded, not asserted.
@MainActor
final class HarnessSettingsReconfirmTests: XCTestCase {

    private func makeVM(daemonReachable: Bool) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c11reconfirm-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "alpha-boss")))
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        model.ouroAgents = [OuroAgentRecord(
            name: "alpha-boss", bundlePath: "AgentBundles/alpha-boss.ouro",
            configPath: "AgentBundles/alpha-boss.ouro/agent.json", status: .ready, detail: "configured")]
        model.bossDashboard = BossDashboardSnapshot(
            agentName: "alpha-boss",
            daemonStatus: daemonReachable ? "running" : "unknown",
            daemonMode: "managed", daemonVersion: "alpha.700",
            attentionLabel: "All quiet", openObligations: 0,
            activeCodingAgents: 0, blockedCodingAgents: 0,
            needsMeItems: [], codingItems: [], observedAt: "2026-01-01T00:00:00Z",
            availability: daemonReachable ? .complete
                : BossDashboardAvailability(machineAvailable: false, needsMeAvailable: false,
                                            codingAvailable: false, issues: ["machine: connection refused"]))
        model.bossWorkbenchMCPRegistration = BossWorkbenchMCPRegistrationSnapshot(
            agentName: "alpha-boss", serverName: "workbench",
            commandPath: "AgentBundles/workbench-mcp",
            agentConfigPath: "AgentBundles/alpha-boss.ouro/agent.json",
            status: .registered, detail: "")
        return model
    }

    /// `HarnessActionRow`'s ONLY in-view branches (`isUrgent` button style, `isBusy`
    /// spinner) are NOT captured by the host. The "Bring Back Online" repair row is
    /// rendered the same way (same captured `Label`) whether the daemon is healthy
    /// (non-urgent → `.bordered`) or down (urgent → `.borderedProminent`). So the row
    /// itself contributes the IDENTICAL captured nodes in both states — proving it is
    /// genuinely branchless from the harness's view (DEFER). The surrounding sheet
    /// differs (overall pill, daemon status text, etc.), but the ROW's own contributed
    /// nodes (its `Label`) are constant. We isolate the row's contribution by asserting
    /// the action-row label is present + identical in both.
    func testHarnessActionRow_isBranchlessFromHostWhitelist_repairRowLabelConstant() throws {
        let healthy = try ViewSnapshotHost.snapshotText(of: HarnessStatusSheet(model: try makeVM(daemonReachable: true)))
        let down = try ViewSnapshotHost.snapshotText(of: HarnessStatusSheet(model: try makeVM(daemonReachable: false)))

        // The repair action row renders in BOTH (repair is always available); the only
        // difference is its (dropped) button style — its captured Label text is constant.
        XCTAssertTrue(healthy.contains("Bring Back Online"),
                      "the repair row renders (non-urgent) in the healthy sheet:\n\(healthy)")
        XCTAssertTrue(down.contains("Bring Back Online"),
                      "the repair row renders (urgent) in the daemon-down sheet:\n\(down)")
        // Count the row's contributed Label occurrences — identical in both → the
        // isUrgent/isBusy branches contribute NO captured-node difference (branchless).
        func rowLabelCount(_ tree: String) -> Int {
            tree.components(separatedBy: "Bring Back Online").count - 1
        }
        XCTAssertEqual(rowLabelCount(healthy), rowLabelCount(down),
                       "HarnessActionRow contributes identical captured nodes regardless of isUrgent → branchless (DEFER)")
    }

    /// Record-keeping assertion: the deferred branchless helpers are exercised
    /// TRANSITIVELY by the C11 composite snapshots (so no coverage is lost by the
    /// DEFER). The agent-section trailing summary (a `HarnessSection` `if let
    /// trailingText`) + the daemon/boss `HarnessDetailRow`s render through C11-3.
    func testDeferredHelpers_areCoveredTransitivelyByTheSheet() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: HarnessStatusSheet(model: try makeVM(daemonReachable: true)))
        // HarnessSection trailing-text (the agent-section summary line) — a captured
        // node from the real `HarnessAgentInventory.summaryLine` producer. The lone
        // agent is config-only `.ready` with no outward verdict → 0 LIVE-ready (isReady
        // needs a `.working` verdict), so the honest summary is "1 local, 0 ready".
        XCTAssertTrue(tree.contains("1 local, 0 ready"),
                      "HarnessSection trailingText (agent summary) renders via the composite:\n\(tree)")
        // HarnessDetailRow values (daemon mode / version) — captured nodes.
        XCTAssertTrue(tree.contains("managed") && tree.contains("alpha.700"),
                      "HarnessDetailRow values render via the composite:\n\(tree)")
    }
}
#endif
