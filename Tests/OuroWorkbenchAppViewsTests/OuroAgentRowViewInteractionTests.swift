#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B7 — `OuroAgentRowView` (`:5982`) INTERACTION drive-to-100%.
///
/// The C7-1 `OuroAgentRowViewTests` snapshot the rendered pills/labels but never EXECUTE the
/// row's `Button(action:)` closures nor the removal-confirmation dialog — so the "Use as Boss"
/// (`:6030`), "Connect tools" (`:6041`), "Reveal Bundle" (`:6051`), "Remove Agent" (`:6062`)
/// actions, the confirmation dialog's confirm/cancel actions (`:6083/6086`), and the
/// `removalConfirmationBinding` get/set closures (`:6107/6108`) were never coloured.
/// ViewInspector 0.10.3 invokes action-closures AND descends `.confirmationDialog`, so this
/// suite DRIVES each and ASSERTS its `@Published` side-effect.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` store seam (AN-001 dual-injection).
/// `agent` is a FIXED `OuroAgentRecord` (relative paths). The Connect button is enabled by an
/// actionable registration injected through the SAME `@Published` map the live refresh writes.
/// To exercise the REAL removal (which deletes the bundle dir + re-scans), the bundle is
/// MATERIALIZED on disk under the hermetic temp `agentBundlesURL` so the inventory scan resolves
/// the live record (`removeAgent` re-resolves by name from the live scan, then deletes).
///
/// **Non-vacuity (P2 — mutation-verified).** Neutering a button/dialog body leaves its flag
/// unset (or the bundle undeleted) after the tap → the corresponding test goes RED.
@MainActor
final class OuroAgentRowViewInteractionTests: XCTestCase {

    /// Build a VM whose hermetic temp `agentBundlesURL` contains a REAL `.ouro` bundle for
    /// `agentName`, so the inventory scan resolves it (needed for the live removal path).
    private func makeVMWithBundle(bossName: String, agentName: String) throws -> (WorkbenchViewModel, URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b7-row-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let bundle = agentBundles.appendingPathComponent("\(agentName).ouro", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        // A minimal agent.json so the scan classifies the bundle as a real installed agent.
        let config = bundle.appendingPathComponent("agent.json")
        try #"{"name":"\#(agentName)","humanFacing":{"provider":"anthropic","model":"claude-opus-4"}}"#
            .data(using: .utf8)!.write(to: config)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(
            WorkspaceState(boss: BossAgentSelection(agentName: bossName)))
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
        model.refreshOuroAgents()
        return (model, bundle)
    }

    private func makeVM(bossName: String = "boss") throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b7-row-\(UUID().uuidString)", isDirectory: true)
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
            name: name,
            bundlePath: "AgentBundles/\(name).ouro",
            configPath: "AgentBundles/\(name).ouro/agent.json",
            status: .ready,
            detail: "ready"
        )
    }

    private func actionableRegistration(for name: String) -> BossWorkbenchMCPRegistrationSnapshot {
        BossWorkbenchMCPRegistrationSnapshot(
            agentName: name, serverName: "ouro_workbench", commandPath: "bin/ouro-workbench-mcp",
            agentConfigPath: "AgentBundles/\(name).ouro/agent.json",
            status: .notRegistered, detail: "not registered")
    }

    // MARK: - Row actions

    /// The non-boss usable row's "Use as Boss" runs `selectBoss` → `state.boss.agentName` flips.
    func testRow_useAsBoss_selectsBoss() throws {
        let model = try makeVM(bossName: "someone-else")
        let row = OuroAgentRowView(agent: record(name: "alpha-agent"), model: model)
        XCTAssertEqual(model.state.boss.agentName, "someone-else")
        try row.inspect().find(button: "Use as Boss").tap()
        XCTAssertEqual(model.state.boss.agentName, "alpha-agent", "Use as Boss runs selectBoss")
    }

    /// The actionable row's "Connect tools" (`:6041`) runs `installWorkbenchMCP`; the hermetic
    /// bundle can't be installed → the honest catch sets `errorMessage`.
    func testRow_connectTools_runsInstall() throws {
        let model = try makeVM(bossName: "someone-else")
        model.bossWorkbenchMCPRegistrationByAgentName["alpha-agent"] = actionableRegistration(for: "alpha-agent")
        let row = OuroAgentRowView(agent: record(name: "alpha-agent"), model: model)
        XCTAssertNil(model.errorMessage)
        try row.inspect().find(button: "Connect tools").tap()
        XCTAssertNotNil(model.errorMessage, "Connect tools runs installWorkbenchMCP → the hermetic install fails honestly")
    }

    /// "Reveal Bundle" (`:6051`) runs `revealAgentBundle`; the Finder boundary is injected so the
    /// tap has an observable target URL and never launches Finder in-process.
    func testRow_revealBundle_runsAction() throws {
        let model = try makeVM(bossName: "someone-else")
        var revealedURLs: [URL] = []
        model.revealFileViewerSelectingURLs = { revealedURLs = $0 }
        let row = OuroAgentRowView(agent: record(name: "alpha-agent"), model: model)
        try row.inspect().find(button: "Reveal Bundle").tap()
        XCTAssertEqual(revealedURLs, [URL(fileURLWithPath: "AgentBundles/alpha-agent.ouro")],
                       "Reveal Bundle targets the bundle, not its nested agent.json")
    }

    /// "Remove Agent" (`:6062`) ARMS the confirmation (sets `agentPendingRemoval`) — it never
    /// deletes on the first tap. This also drives the `removalConfirmationBinding` GET closure
    /// (`:6107`), which now resolves true for this row (its id matches the armed agent).
    func testRow_remove_armsConfirmation() throws {
        let model = try makeVM(bossName: "someone-else")
        let agent = record(name: "alpha-agent")
        let row = OuroAgentRowView(agent: agent, model: model)
        XCTAssertNil(model.agentPendingRemoval, "precondition: nothing armed")
        try row.inspect().find(button: "Remove Agent").tap()
        XCTAssertEqual(model.agentPendingRemoval?.id, agent.id, "Remove arms the confirmation for THIS row")
    }

    /// The confirmation dialog's CONFIRM action (`:6083`) runs `removeAgent`, which deletes the
    /// on-disk bundle + re-scans. Materialize a real bundle so the live-resolve + delete runs.
    func testRow_confirmRemoval_deletesBundle() throws {
        let (model, bundle) = try makeVMWithBundle(bossName: "someone-else", agentName: "alpha-agent")
        let agent = try XCTUnwrap(model.ouroAgents.first { $0.name == "alpha-agent" },
                                  "provenance: the materialized bundle is in the scan")
        model.agentPendingRemoval = agent          // arm (the prod path that opens the dialog)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path), "precondition: bundle on disk")

        let row = OuroAgentRowView(agent: agent, model: model)
        try row.inspect().find(ViewType.ConfirmationDialog.self)
            .find(button: AgentRemoval.confirmationCopy(agentName: "alpha-agent", isBoss: false).confirmTitle)
            .tap()

        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path),
                       "confirm runs removeAgent → the bundle directory is deleted")
        XCTAssertNil(model.agentPendingRemoval, "removeAgent clears the armed flag")
    }

    /// The confirmation dialog's CANCEL action (`:6086`) clears `agentPendingRemoval` WITHOUT
    /// deleting the bundle. This also drives the binding SET closure (`:6108`).
    func testRow_cancelRemoval_clearsArmWithoutDeleting() throws {
        let (model, bundle) = try makeVMWithBundle(bossName: "someone-else", agentName: "alpha-agent")
        let agent = try XCTUnwrap(model.ouroAgents.first { $0.name == "alpha-agent" })
        model.agentPendingRemoval = agent
        let row = OuroAgentRowView(agent: agent, model: model)
        try row.inspect().find(ViewType.ConfirmationDialog.self)
            .find(button: AgentRemoval.confirmationCopy(agentName: "alpha-agent", isBoss: false).cancelTitle)
            .tap()
        XCTAssertNil(model.agentPendingRemoval, "cancel clears the armed flag")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path),
                      "cancel does NOT delete the bundle")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The actions are load-bearing: Remove arms, Use-as-Boss flips the boss, confirm deletes.
    func testRow_negativeControl_actionsAreLoadBearing() throws {
        let arm = try makeVM(bossName: "someone-else")
        let agent = record(name: "alpha-agent")
        try OuroAgentRowView(agent: agent, model: arm).inspect().find(button: "Remove Agent").tap()
        XCTAssertEqual(arm.agentPendingRemoval?.id, agent.id, "Remove armed (the action ran)")

        let boss = try makeVM(bossName: "someone-else")
        try OuroAgentRowView(agent: record(name: "alpha-agent"), model: boss).inspect().find(button: "Use as Boss").tap()
        XCTAssertEqual(boss.state.boss.agentName, "alpha-agent", "Use-as-Boss ran")
    }
}
#endif
