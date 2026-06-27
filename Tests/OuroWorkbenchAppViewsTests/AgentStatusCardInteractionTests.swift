#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B7 — `AgentStatusCard` (`:8376`) INTERACTION drive-to-100%.
///
/// The C7-3 `AgentStatusCardTests` snapshot the rendered branches (the headline/icon/pill +
/// the actionable Connect button LABEL) but never EXECUTE the Connect-tools `Button(action:)`
/// closure (`:8398` — the one uncovered region). ViewInspector 0.10.3 invokes
/// action-closures (`find(button:).tap()`, the B2 finding), so this suite DRIVES the
/// `model.installWorkbenchMCP(for:)` action and ASSERTS its observable side-effect.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` store seam (AN-001 dual-injection:
/// a temp `agentBundlesURL` into BOTH the registrar AND the inventory). The button is enabled
/// by an actionable (`.notRegistered`) `BossWorkbenchMCPRegistrationSnapshot` — a real Core
/// value. The agent's bundle does NOT exist on disk (the hermetic temp dir), so the
/// registrar's `.install(for:)` throws → `installWorkbenchMCP` takes its honest `catch` arm
/// and sets `errorMessage` (an observable `@Published`), then re-reads the registration. The
/// tap runs the REAL production action against the REAL hermetic seam — nothing fabricated.
///
/// **Non-vacuity (P2 — mutation-verified).** Breaking the action body (e.g. `// model.install…`)
/// leaves `errorMessage == nil` after the tap → `testCard_connectTools_runsInstall` goes RED.
@MainActor
final class AgentStatusCardInteractionTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b7-card-\(UUID().uuidString)", isDirectory: true)
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

    private func record(name: String = "alpha-agent") -> OuroAgentRecord {
        OuroAgentRecord(
            name: name,
            bundlePath: "AgentBundles/\(name).ouro",
            configPath: "AgentBundles/\(name).ouro/agent.json",
            status: .ready,
            detail: "ready"
        )
    }

    private func actionableRegistration(for name: String = "alpha-agent") -> BossWorkbenchMCPRegistrationSnapshot {
        BossWorkbenchMCPRegistrationSnapshot(
            agentName: name,
            serverName: "ouro_workbench",
            commandPath: "bin/ouro-workbench-mcp",
            agentConfigPath: "AgentBundles/\(name).ouro/agent.json",
            status: .notRegistered,
            detail: "not registered"
        )
    }

    /// The actionable "Connect Workbench tools" button (`:8398`) runs `installWorkbenchMCP`.
    /// Against the hermetic (non-existent) temp bundle the registrar throws → the action's
    /// honest `catch` arm sets `errorMessage`. Asserting that proves the action body executed.
    func testCard_connectTools_runsInstall() throws {
        let model = try makeVM()
        let reg = actionableRegistration()
        XCTAssertEqual(reg.isActionable, true, "provenance: .notRegistered is actionable → the button renders")
        XCTAssertNil(model.errorMessage, "precondition: no error yet")

        let card = AgentStatusCard(agent: record(), model: model, registration: reg)
        try card.inspect().find(button: "Connect Workbench tools").tap()

        XCTAssertNotNil(model.errorMessage,
                        "tapping Connect Workbench tools runs installWorkbenchMCP; the hermetic bundle can't be installed → the honest catch sets errorMessage")
        XCTAssertTrue(model.errorMessage?.contains("alpha-agent") == true,
                      "the error names the agent the action targeted: \(model.errorMessage ?? "nil")")
    }
}
#endif
