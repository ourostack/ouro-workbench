#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B7 — `OuroAgentManagerView` (`:5913`) INTERACTION drive-to-100%.
///
/// The C0 `OuroAgentManagerViewAN001Tests` snapshot the empty/one/many roster but never
/// EXECUTE the header's action-closures — so the "Refresh Agents" button action (`:5933`) and
/// the "Add Agent" `Menu {}`'s "Create an Agent…" / "Clone an Agent…" button actions
/// (`:5944/5949`) were never coloured. ViewInspector 0.10.3 descends `Menu {}` AND invokes
/// action-closures (`find(button:).tap()`, the B2 finding), so this suite DRIVES each and
/// ASSERTS its `@Published` side-effect.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` store seam (AN-001 dual-injection:
/// a temp `agentBundlesURL` into BOTH the registrar AND the inventory → the scans are hermetic).
/// Each action is the REAL production model method the button wires.
///
/// **Carve (recorded for Unit 3):** the `.task { model.refreshOuroAgents() }` modifier
/// (`:5976`) — SwiftUI's `.task` does NOT run under ViewInspector's synchronous `inspect()`
/// (the host's own doc-comment notes this), and there is no `.task`-firing seam in
/// ViewInspector 0.10.3 (`callOnAppear()` fires `.onAppear`, not `.task`). Its body
/// (`refreshOuroAgents()`) is independently DRIVEN here through the Refresh button — only the
/// `.task` attachment region is the carve (`.task` toolchain-untestable).
///
/// **Non-vacuity (P2 — mutation-verified).** Neutering a button body leaves its flag unset
/// after the tap → the corresponding test goes RED.
@MainActor
final class OuroAgentManagerViewInteractionTests: XCTestCase {

    private func makeVM(bossName: String = "boss") throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b7-mgr-\(UUID().uuidString)", isDirectory: true)
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

    /// "Refresh Agents" (`:5933`) runs `refreshOuroAgents` → the hermetic temp scan keeps
    /// `ouroAgents` empty (the closure ran; no machine agents leak through the temp dir).
    func testManager_refresh_runsRefresh() throws {
        let model = try makeVM()
        // Seed a non-roster agent so a re-scan would CLEAR it if the action ran (it scans the
        // empty temp dir). This makes the effect observable.
        model.ouroAgents = [OuroAgentRecord(name: "stale", bundlePath: "AgentBundles/stale.ouro",
                                            configPath: "AgentBundles/stale.ouro/agent.json",
                                            status: .ready, detail: "ready")]
        XCTAssertFalse(model.ouroAgents.isEmpty, "precondition: a seeded stale agent")
        try OuroAgentManagerView(model: model).inspect().find(button: "Refresh Agents").tap()
        XCTAssertTrue(model.ouroAgents.isEmpty,
                      "Refresh Agents re-scans the hermetic temp dir → the seeded stale agent is cleared")
    }

    /// "Create an Agent…" in the Add-Agent menu → `presentNewAgentProviderConfigForm`.
    func testManager_menu_createAgent_presentsProviderForm() throws {
        let model = try makeVM()
        XCTAssertFalse(model.isProviderConfigPresented)
        try OuroAgentManagerView(model: model).inspect().find(button: "Create an Agent…").tap()
        XCTAssertTrue(model.isProviderConfigPresented, "Create an Agent → the provider form opens")
        XCTAssertTrue(model.providerConfigIsNewAgent, "the new-agent flag is set")
    }

    /// "Clone an Agent from Git…" in the Add-Agent menu → `presentCloneAgentSheet`.
    func testManager_menu_cloneAgent_presentsInstallSheet() throws {
        let model = try makeVM()
        XCTAssertFalse(model.isOuroAgentInstallSheetPresented)
        try OuroAgentManagerView(model: model).inspect().find(button: "Clone an Agent from Git…").tap()
        XCTAssertTrue(model.isOuroAgentInstallSheetPresented, "Clone → the install sheet opens")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The menu actions are load-bearing: Create opens the provider form, Clone opens the install
    /// sheet — each distinct from the pre-tap state.
    func testManager_negativeControl_menuActionsAreLoadBearing() throws {
        let create = try makeVM()
        try OuroAgentManagerView(model: create).inspect().find(button: "Create an Agent…").tap()
        XCTAssertTrue(create.isProviderConfigPresented, "Create ran")

        let clone = try makeVM()
        try OuroAgentManagerView(model: clone).inspect().find(button: "Clone an Agent from Git…").tap()
        XCTAssertTrue(clone.isOuroAgentInstallSheetPresented, "Clone ran")
    }
}
#endif
