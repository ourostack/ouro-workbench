#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B2 — `AutonomyStatusPopover` (`:4671`) footer-action drive (K1 PARTIAL split, D9).
///
/// `AutonomyStatusPopover` is constructed STANDALONE (it is the top-level view here, NOT presented via
/// `.popover`), so ViewInspector descends its footer buttons and CAN tap them. The C3
/// `AutonomyStatusPopoverStandaloneTests` snapshot the header/check rows + the MCP Connect button's
/// LABEL but never EXECUTE the footer action closures, and never drive the `degradedCheckIds` boss-mcp
/// branch. Per D9 the partial carve is split: the login-tainted arms stay carves, the rest are DRIVEN.
///
/// **DRIVEN (non-login):**
///   - the watch footer button action `{ model.setBossWatchEnabled(...) }` (`:4780`) + BOTH label
///     ternary arms (`:4784`/`:4785`): driven from watch-ON ("Pause Watch") and watch-OFF ("Watch").
///   - the "Connect" MCP button action `{ model.installWorkbenchMCPForBoss() }` (`:4770`) via tap
///     (a real `.notRegistered` actionable registration makes it render).
///   - the check-in button action `{ model.attemptCheckIn() }` (`:4797`) via tap.
///   - the `degradedCheckIds` boss-mcp branch (`:4711`): a non-actionable registration + a boss-mcp
///     `.blocker` check inserts "boss-mcp".
///
/// **CARVE (recorded for Unit 3 — non-injectable `LoginItemController`):**
///   - the `if loginItem.status == .appBundleMissing { ids.insert("open-at-login") }` branch (`:4714`)
///     and the `if !loginItem.isEnabled` "Login"/"Update Login" footer button + its action/label
///     (`:4790`–`:4795`): `LoginItemController.status`/`isEnabled` are non-injectable, machine-local.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` (AN-001). `AutonomyReadinessSnapshot(checks:)`
/// + `BossWorkbenchMCPRegistrationSnapshot` are public Core seams (the same the live builders emit).
@MainActor
final class AutonomyStatusPopoverInteractionTests: XCTestCase {

    private func makeVM(watchEnabled: Bool = true) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b2-aspi-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        var state = WorkspaceState(boss: BossAgentSelection(agentName: "boss"))
        state.bossWatchEnabled = watchEnabled
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    private func check(_ id: String, _ label: String, _ state: AutonomyReadinessCheckState) -> AutonomyReadinessCheck {
        AutonomyReadinessCheck(id: id, label: label, detail: "\(label).", state: state)
    }

    private func popover(_ model: WorkbenchViewModel, checks: [AutonomyReadinessCheck]) -> AutonomyStatusPopover {
        AutonomyStatusPopover(snapshot: AutonomyReadinessSnapshot(checks: checks),
                              model: model, loginItem: LoginItemController())
    }

    private func okChecks() -> [AutonomyReadinessCheck] {
        [check("boss", "Boss", .ok), check("boss-watch", "Boss watch", .ok)]
    }

    // MARK: - Watch footer button (both label ternary arms + the action)

    /// Watch ON → the footer button reads "Pause Watch"; tapping pauses (sets watch OFF).
    func testPopover_watchButton_pause() throws {
        let model = try makeVM(watchEnabled: true)
        XCTAssertTrue(model.bossWatchIsEnabled, "precondition: watch ON")
        try popover(model, checks: okChecks()).inspect().find(button: "Pause Watch").tap()
        XCTAssertFalse(model.bossWatchIsEnabled, "Pause Watch disables boss watch")
    }

    /// Watch OFF → the footer button reads "Watch"; tapping enables it (the other ternary arm).
    func testPopover_watchButton_start() throws {
        let model = try makeVM(watchEnabled: false)
        XCTAssertFalse(model.bossWatchIsEnabled, "precondition: watch OFF")
        try popover(model, checks: okChecks()).inspect().find(button: "Watch").tap()
        XCTAssertTrue(model.bossWatchIsEnabled, "Watch enables boss watch")
        model.setBossWatchEnabled(false)  // stop the watch loop the tap started
    }

    // MARK: - Connect (MCP) footer button action

    /// A real `.notRegistered` (actionable) registration renders the "Connect" button; tapping it
    /// invokes `installWorkbenchMCPForBoss()` (the action region).
    func testPopover_connectButton_runsAction() throws {
        let model = try makeVM()
        model.bossWorkbenchMCPRegistration = BossWorkbenchMCPRegistrationSnapshot(
            agentName: "boss", serverName: "workbench", commandPath: "AgentBundles/workbench-mcp",
            agentConfigPath: "AgentBundles/boss.ouro/agent.json", status: .notRegistered, detail: "")
        XCTAssertTrue(model.bossWorkbenchMCPRegistration?.isActionable == true, "provenance: actionable")
        try popover(model, checks: okChecks()).inspect().find(button: "Connect").tap()
    }

    // MARK: - Check-in footer button action

    /// The "Check In" footer button action invokes `attemptCheckIn()`. With a boss set but unreachable
    /// (no installed agent), it routes to `isHarnessStatusPresented`; either way the action region runs.
    func testPopover_checkInButton_runsAction() throws {
        let model = try makeVM()
        try popover(model, checks: okChecks()).inspect().find(button: WorkbenchViewModel.checkInActionLabel).tap()
        // The action ran (no throw). The check-in routes per availability; the region is covered.
    }

    // MARK: - degradedCheckIds boss-mcp branch

    /// A NON-actionable (`.registered`) MCP registration + a boss-mcp `.blocker` check exercises the
    /// `if model.bossWorkbenchMCPRegistration?.isActionable == false, snapshot.checks.contains(...)`
    /// branch that inserts "boss-mcp" into `degradedCheckIds` — driving the boss-mcp row's degraded tone.
    func testPopover_degradedCheckIds_bossMcpBranch() throws {
        let model = try makeVM()
        model.bossWorkbenchMCPRegistration = BossWorkbenchMCPRegistrationSnapshot(
            agentName: "boss", serverName: "workbench", commandPath: "AgentBundles/workbench-mcp",
            agentConfigPath: "AgentBundles/boss.ouro/agent.json", status: .registered, detail: "")
        XCTAssertFalse(model.bossWorkbenchMCPRegistration?.isActionable == true, "provenance: not actionable")
        let checks = [check("boss", "Boss", .ok), check("boss-mcp", "Workbench tools", .blocker)]
        // The boss-mcp blocker row renders the loud (degraded) glyph because the branch inserts it.
        let tree = try ViewSnapshotHost.snapshotText(of: popover(model, checks: checks))
        XCTAssertTrue(tree.contains("xmark.octagon.fill"), "the boss-mcp degraded octagon renders:\n\(tree)")
    }
}
#endif
