#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B7 — `AgentHomeEmptyState` (`:2817`) INTERACTION drive-to-100%.
///
/// The C8 `AgentHomeEmptyStateTests` snapshot the intro + the three gate-free button LABELS +
/// the installed-agents card, but never EXECUTE the button actions — so the "New Terminal"
/// (`:2854` → `createBlankTerminal`), "Set up a boss" (`:2866` → `presentOnboarding`),
/// "Create an Agent" (`:2879` → `presentNewAgentProviderConfigForm`) actions and the
/// installed-row `select:` closure (`:2914` → `selectAgent`) were never coloured.
/// ViewInspector 0.10.3 invokes action-closures (`find(button:).tap()`, the B2 finding), so
/// this suite DRIVES each and ASSERTS its `@Published` side-effect.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` store seam (AN-001 dual-injection).
/// The installed-agents card is driven by a FIXED injected `OuroAgentRecord` (the `@Published`
/// the inventory scan also writes). Each action is the REAL production model method.
///
/// **Non-vacuity (P2 — mutation-verified).** Neutering a button body leaves its flag unset
/// (or no session created) after the tap → the corresponding test goes RED.
@MainActor
final class AgentHomeEmptyStateInteractionTests: XCTestCase {

    private func makeVM(bossName: String = "boss") throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b7-home-\(UUID().uuidString)", isDirectory: true)
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

    private func record(name: String) -> OuroAgentRecord {
        OuroAgentRecord(
            name: name, bundlePath: "AgentBundles/\(name).ouro",
            configPath: "AgentBundles/\(name).ouro/agent.json", status: .ready, detail: "ready")
    }

    /// "New Terminal" (`:2854`) runs `createBlankTerminal` → a blank session is created
    /// (the synchronous effect: `processEntries` grows; the async PTY launch is enqueued, not
    /// awaited — the B2 Recover-All precedent).
    func testHome_newTerminal_createsBlankSession() throws {
        let model = try makeVM()
        XCTAssertTrue(model.state.processEntries.isEmpty, "precondition: no sessions")
        try AgentHomeEmptyState(model: model).inspect()
            .find(button: AgentHomeEmptyStateCopy.newTerminalButton).tap()
        XCTAssertFalse(model.state.processEntries.isEmpty,
                       "New Terminal runs createBlankTerminal → a blank session is created")
    }

    /// "Set up a boss" (`:2866`) runs `presentOnboarding` → `isOnboardingPresented` flips.
    func testHome_setUpBoss_presentsOnboarding() throws {
        let model = try makeVM()
        XCTAssertFalse(model.isOnboardingPresented)
        try AgentHomeEmptyState(model: model).inspect()
            .find(button: AgentHomeEmptyStateCopy.setUpBossButton).tap()
        XCTAssertTrue(model.isOnboardingPresented, "Set up a boss → onboarding opens")
    }

    /// "Create an Agent" (`:2879`) runs `presentNewAgentProviderConfigForm` → the provider form.
    func testHome_createAgent_presentsProviderForm() throws {
        let model = try makeVM()
        XCTAssertFalse(model.isProviderConfigPresented)
        try AgentHomeEmptyState(model: model).inspect()
            .find(button: AgentHomeEmptyStateCopy.createAgentButton).tap()
        XCTAssertTrue(model.isProviderConfigPresented, "Create an Agent → the provider form opens")
        XCTAssertTrue(model.providerConfigIsNewAgent, "the new-agent flag is set")
    }

    /// The installed-agents card's `SidebarAgentRow` `select:` closure (`:2914`) runs
    /// `selectAgent` → `selectedAgentName` flips to the tapped agent.
    func testHome_installedRow_selectsAgent() throws {
        let model = try makeVM(bossName: "someone-else")
        model.ouroAgents = [record(name: "alpha-agent")]   // the @Published the scan writes
        XCTAssertNil(model.selectedAgentName, "precondition: no agent selected")
        try AgentHomeEmptyState(model: model).inspect()
            .find(SidebarAgentRow.self).find(ViewType.Button.self).tap()
        XCTAssertEqual(model.selectedAgentName, "alpha-agent",
                       "tapping the installed row runs selectAgent(agent.name)")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The actions are load-bearing: Set-up-boss opens onboarding, Create opens the provider
    /// form, the installed row selects the agent — each distinct from the pre-tap state.
    func testHome_negativeControl_actionsAreLoadBearing() throws {
        let boss = try makeVM()
        try AgentHomeEmptyState(model: boss).inspect()
            .find(button: AgentHomeEmptyStateCopy.setUpBossButton).tap()
        XCTAssertTrue(boss.isOnboardingPresented, "Set-up-boss ran")

        let select = try makeVM(bossName: "someone-else")
        select.ouroAgents = [record(name: "alpha-agent")]
        try AgentHomeEmptyState(model: select).inspect()
            .find(SidebarAgentRow.self).find(ViewType.Button.self).tap()
        XCTAssertEqual(select.selectedAgentName, "alpha-agent", "the select closure ran")
    }
}
#endif
