#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B2 — `BossSelectorView` (`:4332`) INTERACTION drive-to-100%.
///
/// The C3 `BossSelectorViewTests` snapshot the always-rendered LABEL but never EXECUTE the
/// `Menu{}` row action-closures nor the `menuLabel(for:)` status-suffix switch arms. ViewInspector
/// 0.10.3 **descends `Menu {}`** (proven), so this suite DRIVES every reachable region:
///   - the per-choice "select this boss" Button action `model.selectBoss(agentName:)` + the
///     checkmark-vs-`Text` arm (selected vs unselected row).
///   - "Use Other Boss…" (sets `draftAgentName` + presents the custom-boss popover binding),
///     "Manage Agents…" (`selectAgent`), "Create an Agent…" (provider form),
///     "Clone an Agent from Git…" (install sheet).
///   - the `menuLabel(for:)` status-suffix arms (authExpired/unreachable/disabled/missingConfig/
///     invalidConfig/missing) driven by injecting `ouroAgents` of each status + an outward verdict.
///
/// **Carve:** the `.popover(isPresented:)` content closure (`BossAgentNamePopover`) is NOT
/// descended by ViewInspector (the documented `.popover` non-descent) — `BossAgentNamePopover` is
/// covered STANDALONE in its own B2 suite. The two `@State` default-value initializers
/// (`customBossIsPresented = false`, `draftAgentName = ""`) are SwiftUI property-wrapper storage
/// initializers with no app seam to flip the default; they are recorded carves.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` (AN-001). `ouroAgents` injected via the
/// SU-E3 `@Published` seam with REAL `OuroAgentRecord`s; the outward verdict via the real
/// `agentOutwardVerdicts` seam (the same `ProviderConnectionVerdict` the live check emits).
@MainActor
final class BossSelectorViewInteractionTests: XCTestCase {

    private func makeVM(bossName: String) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b2-bsv-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(
            WorkspaceState(boss: BossAgentSelection(agentName: bossName)))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    private func record(_ name: String, _ status: OuroAgentBundleStatus) -> OuroAgentRecord {
        OuroAgentRecord(
            name: name, bundlePath: "AgentBundles/\(name).ouro",
            configPath: "AgentBundles/\(name).ouro/agent.json",
            status: status, detail: status.rawValue)
    }

    private func selector(_ model: WorkbenchViewModel) -> BossSelectorView { BossSelectorView(model: model) }

    // MARK: - Menu row actions (Menu {} IS descended)

    /// The per-choice "select this boss" Button action calls `selectBoss(agentName:)`. With a
    /// boss currently "alpha", selecting "bravo" flips `state.boss.agentName`. Also drives the
    /// UNSELECTED-row `else` arm (the chosen-vs-other row uses `Text` not the checkmark `Label`).
    func testSelector_selectBossRow_changesBoss() throws {
        let model = try makeVM(bossName: "alpha")
        model.ouroAgents = [record("alpha", .ready), record("bravo", .ready)]
        XCTAssertEqual(model.state.boss.agentName, "alpha", "precondition: alpha is boss")
        // The "bravo" row is an UNSELECTED Text row; tapping it selects bravo.
        try selector(model).inspect().find(button: "bravo").tap()
        XCTAssertEqual(model.state.boss.agentName, "bravo", "selecting the row changes the boss")
    }

    /// "Use Other Boss…" seeds the draft name from the current boss and flips the popover binding.
    /// (The binding flip is internal `@State`; the action region is driven and does not throw.)
    func testSelector_useOtherBoss_runs() throws {
        let model = try makeVM(bossName: "alpha")
        model.ouroAgents = [record("alpha", .ready)]
        try selector(model).inspect().find(button: "Use Other Boss…").tap()
    }

    /// "Manage Agents…" calls `selectAgent(state.boss.agentName)`; with the boss installed it sets
    /// `selectedAgentName`.
    func testSelector_manageAgents_selectsAgent() throws {
        let model = try makeVM(bossName: "alpha")
        model.ouroAgents = [record("alpha", .ready)]
        XCTAssertNil(model.selectedAgentName)
        try selector(model).inspect().find(button: "Manage Agents…").tap()
        XCTAssertEqual(model.selectedAgentName, "alpha", "Manage Agents selects the boss agent")
    }

    func testSelector_createAgent_presentsProviderForm() throws {
        let model = try makeVM(bossName: "alpha")
        model.ouroAgents = [record("alpha", .ready)]
        XCTAssertFalse(model.isProviderConfigPresented)
        try selector(model).inspect().find(button: "Create an Agent…").tap()
        XCTAssertTrue(model.isProviderConfigPresented)
    }

    func testSelector_cloneAgent_presentsInstallSheet() throws {
        let model = try makeVM(bossName: "alpha")
        model.ouroAgents = [record("alpha", .ready)]
        XCTAssertFalse(model.isOuroAgentInstallSheetPresented)
        try selector(model).inspect().find(button: "Clone an Agent from Git…").tap()
        XCTAssertTrue(model.isOuroAgentInstallSheetPresented)
    }

    // MARK: - menuLabel(for:) status-suffix switch arms

    /// Inject agents of every status + outward verdict so the `menuLabel(for:)` switch exercises
    /// each suffix arm: a `.ready` agent with `.unauthorized` verdict → "— sign-in needed";
    /// `.unreachable` → "— offline"; `.disabled`/`.missingConfig`/`.invalidConfig` → their suffixes;
    /// an unresolved name → "— missing". The Menu renders one row per choice → menuLabel runs for each.
    func testSelector_menuLabel_allStatusSuffixes() throws {
        let model = try makeVM(bossName: "ready-bare")
        model.ouroAgents = [
            record("ready-bare", .ready),
            record("auth-exp", .ready),
            record("offline", .ready),
            record("disabled-a", .disabled),
            record("missing-cfg", .missingConfig),
            record("invalid-cfg", .invalidConfig)
        ]
        model.agentOutwardVerdicts = ["auth-exp": .unauthorized, "offline": .unreachable]
        // Sanity: the choices include every injected name (the Menu renders a row → menuLabel each).
        let choices = Set(model.bossAgentChoices)
        for n in ["ready-bare", "auth-exp", "offline", "disabled-a", "missing-cfg", "invalid-cfg"] {
            XCTAssertTrue(choices.contains(n), "provenance: \(n) is a boss choice")
        }
        // Drive the body so every row's menuLabel evaluates. find(button:) over a suffix proves it.
        let view = selector(model)
        try view.inspect().find(button: "auth-exp — sign-in needed").tap()  // the .authExpired arm label
        // Re-build (selecting changed the boss); assert each other suffix appears as a row label.
        let model2 = try makeVM(bossName: "ready-bare")
        model2.ouroAgents = model.ouroAgents
        model2.agentOutwardVerdicts = model.agentOutwardVerdicts
        let v2 = selector(model2)
        try v2.inspect().find(button: "offline — offline").tap()         // the .unreachable arm
        let model3 = try makeVM(bossName: "ready-bare")
        model3.ouroAgents = model.ouroAgents
        let v3 = selector(model3)
        try v3.inspect().find(button: "disabled-a — disabled").tap()     // the .disabled arm
        let model4 = try makeVM(bossName: "ready-bare")
        model4.ouroAgents = model.ouroAgents
        let v4 = selector(model4)
        try v4.inspect().find(button: "missing-cfg — no agent.json").tap()  // the .missingConfig arm
        let model5 = try makeVM(bossName: "ready-bare")
        model5.ouroAgents = model.ouroAgents
        let v5 = selector(model5)
        try v5.inspect().find(button: "invalid-cfg — invalid config").tap()  // the .invalidConfig arm
    }

    /// The "— missing" arm: a boss choice whose name doesn't resolve to a record. `bossAgentChoices`
    /// includes the persisted `state.boss.agentName` even with no record, so a boss name with no
    /// matching `ouroAgents` entry renders the "<name> — missing" suffix.
    func testSelector_menuLabel_missingArm() throws {
        let model = try makeVM(bossName: "ghost")
        // No ouroAgents → "ghost" resolves to no record → the guard-let-else "missing" arm.
        XCTAssertNil(model.ouroAgent(named: "ghost"))
        XCTAssertTrue(model.bossAgentChoices.contains("ghost"), "the persisted boss is a choice")
        try selector(model).inspect().find(button: "ghost — missing").tap()
    }

    // MARK: - Determinism (P3)

    func testSelector_interaction_noLeak() throws {
        let model = try makeVM(bossName: "alpha")
        model.ouroAgents = [record("alpha", .ready)]
        let tree = try ViewSnapshotHost.snapshotText(of: selector(model))
        XCTAssertFalse(tree.contains("/Users/"), "no machine-path leak:\n\(tree)")
    }
}
#endif
