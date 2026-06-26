#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B1 — `WorkbenchSidebarView` (`:3025`) action-closure + conditional-arm INTERACTION
/// drive-to-100%.
///
/// The SU3 `SidebarSurfaceStateSetTests` snapshot the workspace rows but never (a) populate
/// `model.ouroAgents` (so the boss-section `ForEach` agent body + the `SidebarAgentRow.select`
/// closure + the "Create Agent"/"Clone" non-empty arms were uncovered), (b) tap the action rows
/// ("Create Your First Agent"/"Create Agent"/"Clone from Git…"/"New Terminal"), nor (c) drive the
/// `if shouldShowRecovery` arm + its Button. This suite drives every reachable region by tapping
/// each button and asserting its `@Published` side-effect, then MUTATION-VERIFIES the load-bearing
/// recovery + New-Terminal actions.
///
/// **Provenance (P2).** The VM is built via the REAL store seam; `model.ouroAgents` is set to a
/// fixed record list (the SAME `@Published` the inventory scan writes — the AutonomyStatusCheckRow
/// precedent for direct `@Published` injection of a scanned value). The Recovery arm is driven by a
/// REAL `.needsRecovery` `ProcessRun` over a real entry+workspace (the AN `testApply_recover`
/// recipe), so `recoveryDigest.actionableCount > 0` through the real producer.
///
/// **Determinism (P3).** Fixed ids; FIXED `/tmp/u5b1sb` working dir; relative agent bundle paths;
/// no clock; `!contains("/Users/")`.
///
/// **Carve (recorded for Unit 3, 6 regions):** the `.task { while !Task.isCancelled { … } }`
/// modifier closure (`L3044:15`, `L3045:19`, `L3045:37`, `L3047:20`, `L3047:37`, `L3047:46`) — a
/// `@MainActor` self-throttling refresh loop that sleeps `SessionChip.refreshIntervalNanoseconds`
/// then loops forever. ViewInspector's `callTask()` would enter this infinite sleep loop and never
/// return (it has no in-process exit seam — it runs until the view disappears), so the loop body
/// is toolchain-untestable in-process. (`.task` toolchain-untestable carve, playbook.)
@MainActor
final class WorkbenchSidebarViewInteractionTests: XCTestCase {

    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
    private static let wsId = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private static let tabId = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!

    private func makeVM(state: WorkspaceState, agents: [OuroAgentRecord] = []) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b1-sb-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
        // The @Published the inventory scan writes — set directly with fixed records (hermetic).
        model.ouroAgents = agents
        return model
    }

    private func agent(_ name: String) -> OuroAgentRecord {
        OuroAgentRecord(
            name: name, bundlePath: "AgentBundles/\(name).ouro",
            configPath: "AgentBundles/\(name).ouro/agent.json",
            status: .ready, detail: "ready", humanFacing: nil
        )
    }

    private func tab(id: UUID = WorkbenchSidebarViewInteractionTests.tabId, name: String = "build") -> ProcessEntry {
        ProcessEntry(id: id, projectId: Self.projectId, name: name, kind: .shell,
                     executable: "/bin/zsh", workingDirectory: "/tmp/u5b1sb")
    }

    private func baseState() -> WorkspaceState {
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            processEntries: [tab()],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: [Self.tabId])]
        )
    }

    private func sidebar(_ model: WorkbenchViewModel) -> WorkbenchSidebarView {
        WorkbenchSidebarView(model: model)
    }

    // MARK: - Agent boss-section: ForEach body + SidebarAgentRow.select closure

    func testAgentsPresent_rendersRowsAndSelectTapSelectsAgent() throws {
        let model = try makeVM(state: baseState(), agents: [agent("alpha"), agent("beta")])
        XCTAssertEqual(model.ouroAgents.count, 2, "provenance: two agents in the boss section")
        let view = sidebar(model)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="alpha""#), "the agent ForEach body renders the row:\n\(tree)")
        // The SidebarAgentRow's Button(action: select) → model.selectAgent(agent.name).
        XCTAssertNil(model.selectedAgentName, "provenance: no agent selected yet")
        try view.inspect().find(SidebarAgentRow.self, where: { try $0.actualView().agent.name == "alpha" })
            .find(ViewType.Button.self).tap()
        XCTAssertEqual(model.selectedAgentName, "alpha", "tapping an agent row selects it (the select closure)")
    }

    // MARK: - "Create Agent" / "Clone from Git…" (non-empty-agents else arm)

    func testAgentsPresent_createAgentTap_presentsProviderForm() throws {
        let model = try makeVM(state: baseState(), agents: [agent("alpha")])
        let view = sidebar(model)
        XCTAssertFalse(model.isProviderConfigPresented, "provenance: provider form not presented")
        try view.inspect().find(button: "Create Agent").tap()
        XCTAssertTrue(model.isProviderConfigPresented, "Create Agent presents the provider-config form")
        XCTAssertTrue(model.providerConfigIsNewAgent, "Create Agent flags a NEW agent")
    }

    func testAgentsPresent_cloneTap_presentsInstallSheet() throws {
        let model = try makeVM(state: baseState(), agents: [agent("alpha")])
        let view = sidebar(model)
        XCTAssertFalse(model.isOuroAgentInstallSheetPresented, "provenance: install sheet not presented")
        try view.inspect().find(button: "Clone from Git…").tap()
        XCTAssertTrue(model.isOuroAgentInstallSheetPresented, "Clone from Git… presents the install sheet")
    }

    // MARK: - "Create Your First Agent" (empty-agents if arm)

    func testNoAgents_createFirstAgentTap_presentsProviderForm() throws {
        let model = try makeVM(state: baseState(), agents: [])
        XCTAssertTrue(model.ouroAgents.isEmpty, "provenance: no agents → the first-agent arm")
        let view = sidebar(model)
        try view.inspect().find(button: "Create Your First Agent").tap()
        XCTAssertTrue(model.isProviderConfigPresented, "Create Your First Agent presents the provider-config form")
    }

    // MARK: - "New Terminal" action

    func testNewTerminalTap_presentsNewSessionSheet() throws {
        let model = try makeVM(state: baseState(), agents: [])
        let view = sidebar(model)
        XCTAssertFalse(model.isNewSessionSheetPresented, "provenance: new-session sheet not presented")
        try view.inspect().find(button: "New Terminal").tap()
        XCTAssertTrue(model.isNewSessionSheetPresented, "New Terminal presents the new-session sheet")
    }

    // MARK: - Recovery section (the shouldShowRecovery true arm + its Button)

    /// A real `.needsRecovery` ProcessRun over a real entry+workspace makes
    /// `recoveryDigest.actionableCount > 0` → `shouldShowRecovery` true → the Recovery section
    /// renders and its Button is reachable. (The AN `testApply_recover` recovery recipe.)
    private func recoverableModel() throws -> WorkbenchViewModel {
        let entryId = UUID(uuidString: "11111111-0000-0000-0000-0000000000EE")!
        let runId = UUID(uuidString: "22222222-0000-0000-0000-0000000000EE")!
        let entry = ProcessEntry(id: entryId, projectId: Self.projectId, name: "respawn-me", kind: .shell,
                                 executable: "/bin/zsh", workingDirectory: "/tmp/u5b1sb",
                                 trust: .trusted, autoResume: true)
        let run = ProcessRun(id: runId, entryId: entryId, status: .needsRecovery,
                             startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            processEntries: [entry],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: [entryId])],
            processRuns: [run]
        )
        return try makeVM(state: state, agents: [])
    }

    func testRecovery_sectionRendersWhenActionable() throws {
        let model = try recoverableModel()
        XCTAssertGreaterThan(model.recoveryDigest.actionableCount, 0, "provenance: a real recoverable entry")
        let tree = try ViewSnapshotHost.snapshotText(of: sidebar(model))
        XCTAssertTrue(tree.contains(model.recoveryDigest.statusLine),
                      "the Recovery section renders the digest status line:\n\(tree)")
    }

    func testRecovery_buttonTap_presentsRecoverySheet() throws {
        let model = try recoverableModel()
        let view = sidebar(model)
        XCTAssertFalse(model.isRecoverySheetPresented, "provenance: recovery sheet not presented")
        // The Recovery Button has no plain title; find it by the digest status-line label it renders.
        try view.inspect().find(button: model.recoveryDigest.statusLine).tap()
        XCTAssertTrue(model.isRecoverySheetPresented, "the Recovery button presents the recovery sheet")
    }

    func testRecovery_negativeControl_hiddenWhenNoActionable() throws {
        // No recoverable runs → shouldShowRecovery false → NO Recovery section (the arm flips).
        let model = try makeVM(state: baseState(), agents: [])
        XCTAssertEqual(model.recoveryDigest.actionableCount, 0, "provenance: nothing recoverable")
        let recoverable = try recoverableModel()
        let withTree = try ViewSnapshotHost.snapshotText(of: sidebar(recoverable))
        let withoutTree = try ViewSnapshotHost.snapshotText(of: sidebar(model))
        XCTAssertNotEqual(withTree, withoutTree, "the shouldShowRecovery arm must flip the tree")
        XCTAssertTrue(withTree.contains(recoverable.recoveryDigest.statusLine), "recoverable: section present")
        XCTAssertFalse(withoutTree.contains("recovery action"), "no recoverable: no Recovery section:\n\(withoutTree)")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The New-Terminal action is load-bearing: tapping it flips isNewSessionSheetPresented.
    /// (Mutation-verify: replacing `model.isNewSessionSheetPresented = true` with a no-op leaves
    /// the flag false → this assertion RED.)
    func testNegativeControl_newTerminalActionPresentsSheet() throws {
        let model = try makeVM(state: baseState(), agents: [])
        let view = sidebar(model)
        let before = model.isNewSessionSheetPresented
        try view.inspect().find(button: "New Terminal").tap()
        XCTAssertNotEqual(before, model.isNewSessionSheetPresented, "New Terminal must change the sheet flag")
    }

    // MARK: - Determinism (P3)

    func testSidebar_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let a = try ViewSnapshotHost.snapshotText(of: sidebar(try makeVM(state: baseState(), agents: [agent("alpha")])))
        let b = try ViewSnapshotHost.snapshotText(of: sidebar(try makeVM(state: baseState(), agents: [agent("alpha")])))
        XCTAssertEqual(a, b, "the agent sidebar must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
    }
}
#endif
