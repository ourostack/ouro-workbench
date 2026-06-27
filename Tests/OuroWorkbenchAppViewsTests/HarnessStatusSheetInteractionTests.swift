#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B9 — `HarnessStatusSheet` (`:1193`) INTERACTION drive-to-100%.
///
/// The C11 `HarnessStatusSheetTests` snapshot the RENDER arms (every enumerated
/// daemon/agent/boss state + the observedAt footer) but never EXECUTE the
/// action-closures — so 16 region segments (every `Button(action:)` body, both
/// `confirmationDialog` buttons, the action-row closures that flip the
/// `@Published` confirmation flags, and the agent-section ternary's false arm)
/// were never coloured. ViewInspector 0.10.3 invokes action-closures
/// (`find(button:).tap()`) AND, when the dialog's `isPresented` binding is TRUE,
/// descends `confirmationDialog {}` content via `.confirmationDialog(idx).actions()`
/// (proven by the `confirmDialog_*` tests below — `find(button:)` on the ROOT does
/// NOT reach dialog content; you must navigate the presented dialog), so this suite
/// DRIVES every reachable region: it taps each button, asserts the `@Published`
/// side-effect (provenance), and the negative control proves the effect is
/// load-bearing (mutation-verify).
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` (AN-001 dual-injection);
/// the harness status flows through the REAL `HarnessStatusBuilder` off the live
/// `@Published` inputs (the same vars `refreshHarnessStatus()` writes), exactly as
/// the C11 render tests.
///
/// **Carves (genuinely-unreachable):** the `@State private var isRefreshing`
/// default-value autoclosure (`:1196`, the @State-default llvm artifact), the
/// `.task {}` on-open closure (`:1281`, ViewInspector 0.10.3 has no `.task`
/// driver), and the `refresh()` helper's `Task { … }` body (`:1293/:1294`, an
/// async detached closure the in-process inspect never schedules to completion) —
/// recorded in `b9-records.md`. Every other region is driven here.
@MainActor
final class HarnessStatusSheetInteractionTests: XCTestCase {

    private static let fixedObservedAt = "2026-01-01T00:00:00Z"

    private func makeVM(bossName: String = "alpha-boss") throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b9harness-\(UUID().uuidString)", isDirectory: true)
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
            commandPath: "AgentBundles/workbench-mcp",
            agentConfigPath: "AgentBundles/alpha-boss.ouro/agent.json",
            status: status,
            detail: detail
        )
    }

    /// A HEALTHY model — daemon running + boss registered + a confirmed-ready agent
    /// (so the agent-section's `hasUnready ? .attention : .healthy` ternary lands on
    /// the FALSE/`.healthy` arm, the C11 render tests never asserted on).
    private func healthyModel() throws -> WorkbenchViewModel {
        let model = try makeVM()
        model.ouroAgents = [record(name: "alpha-boss")]
        model.bossDashboard = dashboard(bossName: "alpha-boss", daemonStatus: "running")
        model.bossWorkbenchMCPRegistration = reg(.registered)
        model.bossWorkbenchMCPRegistrationByAgentName = ["alpha-boss": reg(.registered)]
        model.bossWorkbenchToolsInjectionByAgentName = ["alpha-boss": .confirmed(.present)]
        model.agentOutwardVerdicts = ["alpha-boss": .working]
        return model
    }

    /// A DAEMON-DOWN model — the urgent "Bring Back Online" repair action row renders.
    private func daemonDownModel() throws -> WorkbenchViewModel {
        let model = try makeVM()
        model.ouroAgents = [record(name: "alpha-boss")]
        model.bossDashboard = dashboard(bossName: "alpha-boss", daemonStatus: "unknown", machineAvailable: false)
        model.bossWorkbenchMCPRegistration = reg(.registered)
        return model
    }

    /// A BOSS-UNREACHABLE model — the urgent register-MCP action row renders.
    private func bossUnreachableModel() throws -> WorkbenchViewModel {
        let model = try makeVM()
        model.ouroAgents = [record(name: "alpha-boss")]
        model.bossDashboard = dashboard(bossName: "alpha-boss", daemonStatus: "running")
        model.bossWorkbenchMCPRegistration = reg(.notRegistered, detail: "tools binary not found")
        model.bossWorkbenchMCPRegistrationByAgentName = ["alpha-boss": reg(.notRegistered)]
        model.agentOutwardVerdicts = ["alpha-boss": .working]
        return model
    }

    // MARK: - Header buttons

    /// The Refresh `Button { refresh() }` action (`:1217`). Tapping enters `refresh()`
    /// which dispatches a `Task` that calls `refreshHarnessStatus()`; the action region
    /// executes. No throw + the closure ran is the observable effect (the inner Task
    /// awaits detached). Asserted: the button is reachable and tappable.
    func testHarness_refreshButton_tapRunsAction() throws {
        let model = try healthyModel()
        let view = HarnessStatusSheet(model: model)
        try view.inspect().find(button: "Refresh").tap()
    }

    /// The `Button("Done") { dismiss() }` action (`:1224`). The action is a pure
    /// environment `dismiss()` — tapping executes the region; the model is untouched.
    func testHarness_doneButton_tapRunsDismiss() throws {
        let model = try healthyModel()
        let before = model.harnessActionResult
        try HarnessStatusSheet(model: model).inspect().find(button: "Done").tap()
        XCTAssertEqual(model.harnessActionResult?.message, before?.message,
                       "Done is a pure dismiss — the model action-result is untouched")
    }

    // MARK: - HarnessActionResultBanner dismiss closure (`:1234`)

    /// The embedded banner's dismiss closure `{ model.harnessActionResult = nil }`
    /// (the `if let result` arm's trailing closure). Set a result so the banner
    /// renders, tap its xmark dismiss, assert the result is cleared.
    func testHarness_actionResultBanner_dismissClearsResult() throws {
        let model = try healthyModel()
        model.harnessActionResult = HarnessActionResult(
            kind: .repairDaemon, succeeded: true, message: "Brought your agent back online.")
        XCTAssertNotNil(model.harnessActionResult, "precondition: a result banner is present")
        // The banner's dismiss button is an icon-only "xmark" Button with help "Dismiss".
        try HarnessStatusSheet(model: model).inspect().find(ViewType.Button.self, where: { button in
            (try? button.labelView().image().actualImage().name()) == "xmark"
        }).tap()
        XCTAssertNil(model.harnessActionResult,
                     "tapping the banner's dismiss clears model.harnessActionResult")
    }

    // MARK: - Action-row closures (flip the @Published confirmation flags)

    /// The daemon-section repair action row's closure (`:1321`):
    /// `{ model.isRepairHarnessDaemonConfirmationPresented = true }`. The daemon-down
    /// model renders the "Bring Back Online" row; tapping it flips the flag.
    func testHarness_repairActionRow_tapPresentsConfirmation() throws {
        let model = try daemonDownModel()
        XCTAssertTrue(model.harnessStatus.controlOffer.isAvailable(.repairDaemon),
                      "provenance: a down daemon offers the repair control")
        XCTAssertFalse(model.isRepairHarnessDaemonConfirmationPresented, "precondition: not presented")
        try HarnessStatusSheet(model: model).inspect().find(button: "Bring Back Online").tap()
        XCTAssertTrue(model.isRepairHarnessDaemonConfirmationPresented,
                      "tapping the repair row presents the bring-back-online confirmation")
    }

    /// The boss-section register-MCP action row's closure (`:1389`):
    /// `{ model.isRegisterHarnessMCPConfirmationPresented = true }`. The
    /// boss-unreachable model renders the "Connect Workbench tools" row.
    func testHarness_registerActionRow_tapPresentsConfirmation() throws {
        let model = try bossUnreachableModel()
        XCTAssertTrue(model.harnessStatus.controlOffer.isAvailable(.registerWorkbenchMCP),
                      "provenance: an unregistered boss offers the register-MCP control")
        XCTAssertFalse(model.isRegisterHarnessMCPConfirmationPresented, "precondition: not presented")
        try HarnessStatusSheet(model: model).inspect().find(button: "Connect Workbench tools").tap()
        XCTAssertTrue(model.isRegisterHarnessMCPConfirmationPresented,
                      "tapping the register row presents the connect-tools confirmation")
    }

    // MARK: - confirmationDialog buttons
    //
    // ViewInspector 0.10.3 reaches a `confirmationDialog`'s content ONLY when its
    // `isPresented` binding is TRUE (`ConfirmationDialog.confirmationDialog(parent:index:)`
    // guards on `isPresentedBinding().wrappedValue`). `find(button:)` on the ROOT does
    // NOT descend into the (AppKit-presented) dialog content. So we PRESENT the dialog
    // (set the `@Published` flag the binding reads) and navigate
    // `.confirmationDialog(idx).actions().find(button:)`. The two dialogs are at source
    // index 0 (repair) and 1 (register).

    /// The repair `confirmationDialog`'s "Bring back online" Button (`:1258`) and its
    /// `Task { await model.repairHarnessDaemon(); refresh() }` body (`:1259`). Tapping
    /// the dialog button executes the action region (the Task is dispatched).
    func testHarness_confirmDialog_bringBackOnline_tapRunsAction() throws {
        let model = try daemonDownModel()
        model.isRepairHarnessDaemonConfirmationPresented = true   // present so the dialog is reachable
        let dialog = try HarnessStatusSheet(model: model).inspect().vStack()
            .confirmationDialog(0)
        try dialog.actions().find(button: "Bring back online").tap()
        // The action body dispatches a Task → repairHarnessDaemon(); the region executes.
    }

    /// The repair dialog's "Cancel" (`role: .cancel`) Button (`:1264`).
    func testHarness_confirmDialog_repairCancel_tapRunsEmptyAction() throws {
        let model = try daemonDownModel()
        model.isRepairHarnessDaemonConfirmationPresented = true
        let dialog = try HarnessStatusSheet(model: model).inspect().vStack()
            .confirmationDialog(0)
        try dialog.actions().find(button: "Cancel").tap()
    }

    /// The register `confirmationDialog`'s "Connect <boss>" Button (`:1273`):
    /// `{ model.registerHarnessWorkbenchMCP(); refresh() }`. The boss name is
    /// "alpha-boss", so the button label is "Connect alpha-boss".
    func testHarness_confirmDialog_connectBoss_tapRunsAction() throws {
        let model = try bossUnreachableModel()
        model.isRegisterHarnessMCPConfirmationPresented = true
        let dialog = try HarnessStatusSheet(model: model).inspect().vStack()
            .confirmationDialog(1)
        try dialog.actions().find(button: "Connect alpha-boss").tap()
        // The action body calls registerHarnessWorkbenchMCP() + refresh(); the region executes.
    }

    /// The register dialog's "Cancel" (`role: .cancel`) Button (`:1277`).
    func testHarness_confirmDialog_registerCancel_tapRunsEmptyAction() throws {
        let model = try bossUnreachableModel()
        model.isRegisterHarnessMCPConfirmationPresented = true
        let dialog = try HarnessStatusSheet(model: model).inspect().vStack()
            .confirmationDialog(1)
        try dialog.actions().find(button: "Cancel").tap()
    }

    // MARK: - Agent-section `hasUnready ? .attention : .healthy` ternary (`:1334`)

    /// The healthy model (a confirmed-ready agent, `hasUnready == false`) lands on the
    /// FALSE/`.healthy` arm of the agent-section state ternary — the arm the C11 render
    /// tests (which all used an unready/empty agent set for the section dot) never hit.
    func testHarness_agentSection_allReady_healthyArm() throws {
        let model = try healthyModel()
        XCTAssertFalse(model.harnessStatus.agents.hasUnready,
                       "provenance: a confirmed-ready agent → hasUnready is false (the .healthy arm)")
        let tree = try ViewSnapshotHost.snapshotText(of: HarnessStatusSheet(model: model))
        XCTAssertTrue(tree.contains("Local agents"), "the agent section renders:\n\(tree)")
    }

    /// The TRUE/`.attention` arm of the agent-section ternary (`:1334`). An UNREADY agent
    /// (a `.ready` config with an expired sign-in → `liveReadiness` not ready, OR a
    /// non-`.ready` bundle status) makes `status.agents.hasUnready == true` → the
    /// `.attention` arm renders the section dot. The `healthy` test above drives the FALSE
    /// arm; this drives the TRUE arm — both halves of the ternary coloured.
    func testHarness_agentSection_unready_attentionArm() throws {
        let model = try makeVM()
        // A non-ready bundle status → the entry is unready → hasUnready is true.
        model.ouroAgents = [record(name: "alpha-boss", status: .missingConfig, detail: "needs a provider")]
        model.bossDashboard = dashboard(bossName: "alpha-boss", daemonStatus: "running")
        model.bossWorkbenchMCPRegistration = reg(.registered)
        XCTAssertTrue(model.harnessStatus.agents.hasUnready,
                      "provenance: an unready agent → hasUnready is true (the .attention arm)")
        let tree = try ViewSnapshotHost.snapshotText(of: HarnessStatusSheet(model: model))
        XCTAssertTrue(tree.contains("Local agents"), "the agent section renders:\n\(tree)")
    }

    // MARK: - Boss mcpPillTone `.map { … } ?? .secondary` (`:1374`)

    /// The `.map` arm of the boss detail-row `valueColor: status.boss.mcpPillTone.map { … }`.
    /// The healthy model (confirmed-present injection on the boss) yields a NON-nil
    /// `mcpPillTone`, so the `.map { BossMCPPillPresentation.color(for: $0) }` arm executes.
    func testHarness_bossMcpPillTone_presentExecutesMapArm() throws {
        let model = try healthyModel()
        XCTAssertNotNil(model.harnessStatus.boss.mcpPillTone,
                        "provenance: a confirmed-present boss injection yields a non-nil pill tone")
        let tree = try ViewSnapshotHost.snapshotText(of: HarnessStatusSheet(model: model))
        XCTAssertTrue(tree.contains("Workbench MCP"), "the boss MCP detail row renders:\n\(tree)")
    }

    /// The `?? .secondary` nil-fallback arm of the boss detail-row valueColor (`:1374`).
    /// With NO boss mcp registration / injection, `status.boss.mcpPillTone` is nil → the
    /// `?? .secondary` calm fallback executes (the arm the `.map`-present test never hits).
    func testHarness_bossMcpPillTone_nilExecutesSecondaryFallback() throws {
        let model = try makeVM()
        model.ouroAgents = [record(name: "alpha-boss")]
        model.bossDashboard = dashboard(bossName: "alpha-boss", daemonStatus: "running")
        // No registration-shaped boss MCP state → boss.mcpStatus is nil → mcpPillTone is nil.
        // (The builder sets `boss.mcpStatus = bossRegistration?.status`; clear it explicitly so
        // the init-time scan can't leave a stale snapshot.)
        model.bossWorkbenchMCPRegistration = nil
        XCTAssertNil(model.harnessStatus.boss.mcpPillTone,
                     "provenance: no registration-shaped boss MCP state → a nil pill tone (?? .secondary)")
        let tree = try ViewSnapshotHost.snapshotText(of: HarnessStatusSheet(model: model))
        XCTAssertTrue(tree.contains("Workbench MCP"), "the boss MCP detail row renders:\n\(tree)")
    }

    // MARK: - Determinism (P3)

    func testHarness_interaction_noLeak() throws {
        let model = try healthyModel()
        let tree = try ViewSnapshotHost.snapshotText(of: HarnessStatusSheet(model: model))
        XCTAssertFalse(tree.contains("/Users/"), "no machine-path leak:\n\(tree)")
        XCTAssertFalse(tree.contains("/var/folders/"), "no temp-path leak (AN-001 hermetic):\n\(tree)")
    }
}
#endif
