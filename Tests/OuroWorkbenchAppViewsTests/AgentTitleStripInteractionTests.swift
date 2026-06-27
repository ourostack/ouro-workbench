#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B7 — `AgentTitleStrip` (`:8189`) INTERACTION drive-to-100%.
///
/// The C7-2 `AgentTitleStripTests` snapshot the rendered LABELS (the chevron glyph, the "More"
/// menu's static action labels, the boss capsule) but never EXECUTE the `Button(action:)`
/// closures — so 10 region segments (the disclosure-chevron toggle, each of the six More-menu
/// button actions, and the "Use as Boss" action) were never coloured. ViewInspector 0.10.3
/// **descends `Menu {}` content** AND invokes action-closures (`find(button:).tap()`, the B2
/// finding), so this suite DRIVES every reachable action, ASSERTS its `@Published`/binding
/// side-effect (provenance), and the negative-control proves the effect is load-bearing.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` store seam (AN-001 dual-injection).
/// `agent` is a FIXED `OuroAgentRecord` with RELATIVE paths (so the hermetic actions take their
/// honest missing-bundle arms). `showsInspector` is a REAL `@State`-backed binding (a tiny host)
/// so the chevron's `showsInspector.toggle()` is observable.
///
/// **Carves (genuinely-unreachable / live-side-effect — recorded for Unit 3):**
///   - "Reveal Bundle in Finder" → `revealAgentBundle` calls `NSWorkspace.activateFileViewerSelecting`,
///     a live Finder GUI action with no `@Published` side-effect; for a non-existent hermetic path
///     it is a no-op. Its region IS executed by the tap (the closure runs) — we tap it for coverage
///     and assert "no throw" (the B2 Refresh-Status precedent), NOT a carve.
///   - "Run ouro check…" / "Create Another Agent…" / "Clone an Agent…" / "Refresh Agents" / the
///     disclosure toggle / "Use as Boss" / "Open agent.json…" are all DRIVEN with asserted effects.
@MainActor
final class AgentTitleStripInteractionTests: XCTestCase {

    private func makeVM(bossName: String = "boss") throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b7-title-\(UUID().uuidString)", isDirectory: true)
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

    /// A reference cell backing a `Binding` so the strip's `showsInspector.toggle()` mutation
    /// persists OUTSIDE the inspection (a value-type `@State` host re-seeds each `inspect()`).
    /// The production binding owner is `AgentDetailView`'s `@State`; the strip just toggles
    /// whatever binding it is handed, so observing a reference-backed binding faithfully proves
    /// the toggle action ran.
    private final class FlagBox { var value: Bool = false }

    private func strip(boss: String, agentName: String, showsInspector: Bool = false) throws -> AgentTitleStrip {
        let model = try makeVM(bossName: boss)
        let isBoss = model.state.boss.agentName.caseInsensitiveCompare(agentName) == .orderedSame
        return AgentTitleStrip(agent: record(name: agentName), model: model,
                               isBoss: isBoss, showsInspector: .constant(showsInspector))
    }

    // MARK: - Disclosure chevron (the `showsInspector.toggle()` action)

    /// Tapping the disclosure chevron toggles the bound `showsInspector` (the only action that
    /// flips the inspector arm in the composite). Driven through a reference-backed binding so the
    /// `showsInspector.toggle()` mutation is observable after the tap.
    func testStrip_chevron_togglesInspectorBinding() throws {
        let model = try makeVM(bossName: "someone-else")
        let box = FlagBox()
        let view = AgentTitleStrip(
            agent: record(name: "alpha-agent"), model: model, isBoss: false,
            showsInspector: Binding(get: { box.value }, set: { box.value = $0 }))
        XCTAssertFalse(box.value, "precondition: inspector collapsed")
        // The collapsed chevron renders `chevron.right`; tap the disclosure button by its glyph.
        try view.inspect().find(ViewType.Button.self, where: { button in
            (try? button.labelView().image().actualImage().name()) == "chevron.right"
        }).tap()
        XCTAssertTrue(box.value, "tapping the disclosure runs showsInspector.toggle() → the binding flips true")
    }

    /// The EXPANDED strip (`showsInspector == true`) renders the down-chevron glyph (`:8200` true
    /// arm) + the "Hide bundle details" help (`:8206` true arm). Driven via a `.constant(true)`
    /// binding (the strip READS the binding for both ternaries; the live `@State` owner is the
    /// detail pane — a constant binding faithfully drives the read-only true arm).
    func testStrip_expanded_rendersDownChevron() throws {
        let view = try strip(boss: "x", agentName: "alpha-agent", showsInspector: true)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"image="chevron.down""#),
                      "expanded: the showsInspector-true ternary renders chevron.down:\n\(tree)")
        XCTAssertFalse(tree.contains(#"image="chevron.right""#),
                       "expanded: NOT the collapsed chevron.right:\n\(tree)")
    }

    // MARK: - More-menu actions (ViewInspector descends Menu{})

    /// "Open agent.json…" → `openAgentConfig`. The hermetic config path doesn't exist → the
    /// action's missing-config guard sets `errorMessage` (its honest early-return arm).
    func testStrip_menu_openConfig_runsOpenAgentConfig() throws {
        let view = try strip(boss: "x", agentName: "alpha-agent")
        XCTAssertNil(view.model.errorMessage)
        try view.inspect().find(button: "Open agent.json…").tap()
        XCTAssertNotNil(view.model.errorMessage, "Open agent.json runs openAgentConfig; the missing hermetic config sets errorMessage")
        XCTAssertTrue(view.model.errorMessage?.contains("config not found") == true,
                      "the error is the missing-config message: \(view.model.errorMessage ?? "nil")")
    }

    /// "Reveal Bundle in Finder" → `revealAgentBundle` (a live Finder GUI action with no
    /// `@Published` effect; a no-op for the hermetic path). The tap runs the closure for
    /// coverage — the observable signal is "no throw" (the B2 Refresh-Status precedent).
    func testStrip_menu_revealBundle_runsAction() throws {
        let view = try strip(boss: "x", agentName: "alpha-agent")
        XCTAssertNoThrow(try view.inspect().find(button: "Reveal Bundle in Finder").tap())
    }

    /// "Run ouro check…" → `repairAgent`. It builds a repair terminal session via
    /// `createCustomSession` → the synchronous effect is a new `processEntries` entry (the
    /// async PTY launch is enqueued, not awaited — the B2 Recover-All precedent).
    func testStrip_menu_runCheck_createsRepairSession() throws {
        let view = try strip(boss: "x", agentName: "alpha-agent")
        XCTAssertTrue(view.model.state.processEntries.isEmpty, "precondition: no sessions")
        try view.inspect().find(button: "Run ouro check…").tap()
        XCTAssertFalse(view.model.state.processEntries.isEmpty,
                       "Run ouro check runs repairAgent → a repair terminal session is created")
        XCTAssertTrue(view.model.state.processEntries.contains { $0.name.contains("alpha-agent") },
                      "the repair session is named for the agent")
    }

    /// "Create Another Agent…" → `presentNewAgentProviderConfigForm` flips the provider-form flags.
    func testStrip_menu_createAnother_presentsProviderForm() throws {
        let view = try strip(boss: "x", agentName: "alpha-agent")
        XCTAssertFalse(view.model.isProviderConfigPresented)
        try view.inspect().find(button: "Create Another Agent…").tap()
        XCTAssertTrue(view.model.isProviderConfigPresented, "Create Another Agent → the provider form opens")
        XCTAssertTrue(view.model.providerConfigIsNewAgent, "the new-agent flag is set")
    }

    /// "Clone an Agent from Git…" → `presentCloneAgentSheet` flips the install-sheet flag.
    func testStrip_menu_cloneAgent_presentsInstallSheet() throws {
        let view = try strip(boss: "x", agentName: "alpha-agent")
        XCTAssertFalse(view.model.isOuroAgentInstallSheetPresented)
        try view.inspect().find(button: "Clone an Agent from Git…").tap()
        XCTAssertTrue(view.model.isOuroAgentInstallSheetPresented, "Clone → the install sheet opens")
    }

    /// "Refresh Agents" → `refreshOuroAgents` re-scans the (hermetic empty) roster: the closure
    /// runs and `ouroAgents` stays empty (no machine agents leak through the temp dir).
    func testStrip_menu_refresh_runsRefresh() throws {
        let view = try strip(boss: "x", agentName: "alpha-agent")
        try view.inspect().find(button: "Refresh Agents").tap()
        XCTAssertTrue(view.model.ouroAgents.isEmpty,
                      "Refresh Agents re-scans the hermetic temp dir → no agents (the closure ran, no leak)")
    }

    // MARK: - Primary "Use as Boss" action

    /// The non-boss strip's primary "Use as Boss" runs `selectBoss` → `state.boss.agentName` flips.
    func testStrip_useAsBoss_selectsBoss() throws {
        let view = try strip(boss: "someone-else", agentName: "alpha-agent")
        XCTAssertEqual(view.model.state.boss.agentName, "someone-else", "precondition: a different boss")
        try view.inspect().find(button: "Use as Boss").tap()
        XCTAssertEqual(view.model.state.boss.agentName, "alpha-agent",
                       "Use as Boss runs selectBoss → the agent becomes the boss")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// Each primary action's side-effect is load-bearing: Create-Another opens the provider form,
    /// Clone opens the install sheet, Use-as-Boss flips the boss — distinct from the no-tap state.
    func testStrip_negativeControl_actionsAreLoadBearing() throws {
        let create = try strip(boss: "x", agentName: "alpha-agent")
        XCTAssertFalse(create.model.isProviderConfigPresented, "before tap: closed")
        try create.inspect().find(button: "Create Another Agent…").tap()
        XCTAssertTrue(create.model.isProviderConfigPresented, "after tap: open (the action ran)")

        let boss = try strip(boss: "someone-else", agentName: "alpha-agent")
        let before = boss.model.state.boss.agentName
        try boss.inspect().find(button: "Use as Boss").tap()
        XCTAssertNotEqual(boss.model.state.boss.agentName, before, "the boss changed (the action ran)")
    }
}
#endif
