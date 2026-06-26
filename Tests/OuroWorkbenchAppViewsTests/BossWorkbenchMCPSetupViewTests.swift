#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C7-5 — `BossWorkbenchMCPSetupView` (`:8037`), the boss's Workbench-MCP setup row. The
/// agent-detail cluster: it renders `model.bossWorkbenchMCPStatusLine` (a fixed model string,
/// no path), the "Workbench MCP" label, a Refresh button, and — conditionally — an Install
/// button.
///
/// **Data-driven branch (the captured-tree flip):**
///   - `if model.bossWorkbenchMCPRegistration?.isActionable == true` → the install
///     `Label(model.bossWorkbenchMCPActionTitle, systemImage: "link.badge.plus")` button.
///   - The status line text routes through `bossWorkbenchMCPStatusLine` (unknown / registered
///     / not-registered → distinct strings).
///
/// **Provenance (P2).** `model` via the `makeVM` dual-injection store seam (AN-001). The boss
/// registration is injected through the SAME `@Published bossWorkbenchMCPRegistration` the
/// live `refreshWorkbenchMCPRegistration()` writes (direct injection IS the production seam).
/// The view's `.task { refreshWorkbenchMCPRegistration() }` does NOT run under the synchronous
/// `inspect()`, so the injected registration survives the snapshot.
@MainActor
final class BossWorkbenchMCPSetupViewTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c7mcp-\(UUID().uuidString)", isDirectory: true)
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

    private func registration(status: BossWorkbenchMCPRegistrationStatus, detail: String) -> BossWorkbenchMCPRegistrationSnapshot {
        BossWorkbenchMCPRegistrationSnapshot(
            agentName: "boss",
            serverName: "ouro_workbench",
            commandPath: "bin/ouro-workbench-mcp",
            agentConfigPath: "AgentBundles/boss.ouro/agent.json",
            status: status,
            detail: detail
        )
    }

    private func view(registration reg: BossWorkbenchMCPRegistrationSnapshot?) throws -> BossWorkbenchMCPSetupView {
        let model = try makeVM()
        model.bossWorkbenchMCPRegistration = reg
        return BossWorkbenchMCPSetupView(model: model)
    }

    // MARK: - Enumerated state-set

    /// No registration → the "unknown" status line, NO install button.
    func testSetup_unknown() throws {
        let view = try view(registration: nil)
        XCTAssertEqual(view.model.bossWorkbenchMCPStatusLine, "unknown", "provenance: no registration")
        try assertViewSnapshot(of: view, named: "BossWorkbenchMCPSetupView.unknown")
    }

    /// A `.registered` registration → "available to boss at runtime", NOT actionable → no
    /// install button.
    func testSetup_registered() throws {
        let view = try view(registration: registration(status: .registered, detail: "registered"))
        XCTAssertEqual(view.model.bossWorkbenchMCPRegistration?.isActionable, false, "provenance: .registered not actionable")
        try assertViewSnapshot(of: view, named: "BossWorkbenchMCPSetupView.registered")
    }

    /// A `.notRegistered` registration → "tools binary missing" + the actionable install
    /// button ("Connect", `link.badge.plus`).
    func testSetup_actionable() throws {
        let view = try view(registration: registration(status: .notRegistered, detail: "not registered"))
        XCTAssertEqual(view.model.bossWorkbenchMCPRegistration?.isActionable, true, "provenance: .notRegistered actionable")
        try assertViewSnapshot(of: view, named: "BossWorkbenchMCPSetupView.actionable")
    }

    // MARK: - U5 B8 — button INTERACTIONS (drive the action closures)

    /// U5 B8 — the Refresh `Button` action (`:8113` — `Button { refreshWorkbenchMCPRegistration() }`).
    /// We seed a SENTINEL `@Published bossWorkbenchMCPRegistration` (a `.registered` snapshot that the
    /// hermetic empty registrar would NEVER produce), find the Refresh button (the first/only
    /// icon-only borderless button in the unknown state), `.tap()` it → `refreshWorkbenchMCPRegistration()`
    /// runs and OVERWRITES the registration with what the registrar reads for an empty bundle (a
    /// not-`.registered` snapshot or nil). ASSERT the sentinel was replaced.
    func testSetup_refreshTap_overwritesRegistration() throws {
        let model = try makeVM()
        // Seed a sentinel that the empty registrar cannot reproduce.
        model.bossWorkbenchMCPRegistration = registration(status: .registered, detail: "SENTINEL")
        XCTAssertEqual(model.bossWorkbenchMCPRegistration?.detail, "SENTINEL", "precondition: sentinel set")
        let view = BossWorkbenchMCPSetupView(model: model)
        // In the unknown/registered state the only button is Refresh (install is gated off).
        try view.inspect().find(ViewType.Button.self).tap()
        XCTAssertNotEqual(model.bossWorkbenchMCPRegistration?.detail, "SENTINEL",
                          "tapping Refresh re-reads the registrar → the sentinel is overwritten")
    }

    /// U5 B8 — the Install `Button` action (`:8123` — `Button { installWorkbenchMCPForBoss() }`),
    /// reachable only when `bossWorkbenchMCPRegistration?.isActionable == true` (a `.notRegistered`
    /// snapshot). We render that arm, find the Install button (the SECOND button — Refresh is first),
    /// `.tap()` it → `installWorkbenchMCPForBoss()` runs. Against the hermetic empty registrar the
    /// install fails (no real bundle) and the VM sets `errorMessage` (the `catch` arm) — an observable
    /// side-effect. ASSERT `errorMessage` went from nil to set.
    func testSetup_installTap_firesInstallSideEffect() throws {
        let model = try makeVM()
        model.bossWorkbenchMCPRegistration = registration(status: .notRegistered, detail: "not registered")
        XCTAssertEqual(model.bossWorkbenchMCPRegistration?.isActionable, true, "precondition: actionable")
        XCTAssertNil(model.errorMessage, "precondition: no error yet")
        let view = BossWorkbenchMCPSetupView(model: model)
        let buttons = try view.inspect().findAll(ViewType.Button.self)
        XCTAssertEqual(buttons.count, 2, "actionable state renders Refresh + Install buttons")
        try buttons[1].tap()  // [0] = Refresh, [1] = Install
        XCTAssertNotNil(model.errorMessage,
                        "tapping Install runs installWorkbenchMCPForBoss → the empty-bundle catch sets errorMessage")
    }

    // MARK: - Determinism (P3)

    func testSetup_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, BossWorkbenchMCPRegistrationSnapshot?)] = [
            ("unknown", nil),
            ("registered", registration(status: .registered, detail: "registered")),
            ("actionable", registration(status: .notRegistered, detail: "not registered"))
        ]
        for (label, reg) in cases {
            let a = try ViewSnapshotHost.snapshotText(of: try view(registration: reg))
            let b = try ViewSnapshotHost.snapshotText(of: try view(registration: reg))
            XCTAssertEqual(a, b, "\(label) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(label): no /Users/ leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The `isActionable` branch adds the install button, and the status line text flips per
    /// registration status — distinct captured trees.
    func testSetup_negativeControl_actionableBranchAndStatusLineFlipTree() throws {
        let unknown = try ViewSnapshotHost.snapshotText(of: try view(registration: nil))
        let registered = try ViewSnapshotHost.snapshotText(of: try view(registration: registration(status: .registered, detail: "registered")))
        let actionable = try ViewSnapshotHost.snapshotText(of: try view(registration: registration(status: .notRegistered, detail: "not registered")))

        XCTAssertNotEqual(unknown, registered, "the status line must flip with the registration status")
        XCTAssertTrue(unknown.contains(#"text="unknown""#), "unknown status line:\n\(unknown)")
        XCTAssertTrue(registered.contains("available to boss at runtime"), "registered status line:\n\(registered)")
        XCTAssertFalse(registered.contains(#"text="Connect""#), "registered: not actionable → no install button:\n\(registered)")

        XCTAssertNotEqual(registered, actionable, "an actionable registration must add the install button")
        XCTAssertTrue(actionable.contains("tools binary missing"), "actionable status line:\n\(actionable)")
        XCTAssertTrue(actionable.contains(#"text="Connect""#), "actionable: the install button:\n\(actionable)")
        XCTAssertTrue(actionable.contains(#"image="link.badge.plus""#), "actionable: the install glyph:\n\(actionable)")
    }
}
#endif
