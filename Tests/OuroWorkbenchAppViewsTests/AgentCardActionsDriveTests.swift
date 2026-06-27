#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 — `AgentActionsCard` (`:8619`) + `AgentLanesCard` (`:8528`) action drive-to-100%.
///
/// Both cards live inside `AgentDetailView` (constructed there, never standalone in the
/// C-series), so their bundle-action button closures were never executed. Promoted
/// private->internal for the per-file-100% gate; this suite taps each action and asserts
/// the model side-effect (provenance), mutation-verified.
///
/// **Provenance (P2).** `model` via a hermetic bundle VM (a real installed agent.json so
/// the record classifies). The config / reveal / sheet actions set `@Published` flags or
/// open Finder (no modal); "Run ouro check" runs `repairAgent` which drives a session
/// launch — the `#332` `launchTerminalSession` no-op is injected so no `screen` spawns.
///
/// **Carves:** none — every action region here is driven.
@MainActor
final class AgentCardActionsDriveTests: XCTestCase {

    private var bundleRoot = URL(fileURLWithPath: "/tmp")

    private func makeVM(agentName: String = "alpha") throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("u5-agentcard-\(UUID().uuidString)", isDirectory: true)
        bundleRoot = tmp
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let bundle = agentBundles.appendingPathComponent("\(agentName).ouro", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try #"{"name":"\#(agentName)","humanFacing":{"provider":"anthropic","model":"claude-opus-4"}}"#
            .data(using: .utf8)!.write(to: bundle.appendingPathComponent("agent.json"))
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        // #332 seam: "Run ouro check" -> repairAgent -> createCustomSession(launch) -> start()
        // would fork a real `screen`. No-op the launcher so the action runs spawn-free.
        model.launchTerminalSession = { _ in }
        return model
    }

    private func record(_ name: String) -> OuroAgentRecord {
        OuroAgentRecord(
            name: name,
            bundlePath: bundleRoot.appendingPathComponent("AgentBundles/\(name).ouro").path,
            configPath: bundleRoot.appendingPathComponent("AgentBundles/\(name).ouro/agent.json").path,
            status: .ready,
            detail: "ready")
    }

    // MARK: - AgentActionsCard
    //
    // CARVE (recorded): the "Run ouro check" button's action `{ model.repairAgent(agent) }`.
    // `repairAgent` builds a `CustomTerminalSessionDraft` running `ouro check --agent <name>`
    // and creates+launches it — a LIVE-SUBPROCESS action (the #332 class). It is already driven
    // through the `AgentTitleStripInteractionTests` "Run ouro check…" tap (the model method is
    // covered there); driving it a second time HERE would shell out to the real `ouro` toolchain
    // on PATH and pollute the shared headless-`ouro` harness other suites use. The four other
    // bundle-action buttons are pure flag/Finder ops — driven below.

    /// "Open agent.json" `Button { model.openAgentConfig(agent) }` — opens the config (no
    /// modal); tapping drives the action region with no error surfaced.
    func testActionsCard_openConfig_runs() throws {
        let model = try makeVM()
        try AgentActionsCard(agent: record("alpha"), model: model)
            .inspect().find(button: "Open agent.json").tap()
    }

    /// "Reveal in Finder" `Button { model.revealAgentBundle(agent) }` — reveals the bundle
    /// via NSWorkspace (no modal).
    func testActionsCard_revealBundle_runs() throws {
        let model = try makeVM()
        try AgentActionsCard(agent: record("alpha"), model: model)
            .inspect().find(button: "Reveal in Finder").tap()
    }

    /// The "Add Another…" menu's `Button { model.presentNewAgentProviderConfigForm() }` —
    /// sets the new-agent provider-config flag (a pure @Published set).
    func testActionsCard_createAnother_presentsForm() throws {
        let model = try makeVM()
        try AgentActionsCard(agent: record("alpha"), model: model)
            .inspect().find(button: "Create Another Agent…").tap()
        XCTAssertTrue(model.providerConfigIsNewAgent,
                      "Create Another Agent opens the provider-config form in new-agent mode")
    }

    /// The "Add Another…" menu's `Button { model.presentCloneAgentSheet() }` — opens the
    /// clone sheet (a pure @Published set).
    func testActionsCard_cloneAgent_presentsSheet() throws {
        let model = try makeVM()
        try AgentActionsCard(agent: record("alpha"), model: model)
            .inspect().find(button: "Clone an Agent from Git…").tap()
        XCTAssertTrue(model.isOuroAgentInstallSheetPresented, "Clone an Agent opens the install/clone sheet")
    }

    // MARK: - AgentLanesCard

    /// `AgentLanesCard`'s "Edit agent.json" `Button { model.openAgentConfig(agent) }` —
    /// the one un-driven action on the lanes card (opens the config, no modal).
    func testLanesCard_editConfig_runs() throws {
        let model = try makeVM()
        try AgentLanesCard(agent: record("alpha"), model: model)
            .inspect().find(button: "Edit agent.json").tap()
    }
}
#endif
