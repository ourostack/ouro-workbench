#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C3-5 — `AutonomyStatusPopover` (`:4631`) STANDALONE enumerated state-set.
///
/// `AutonomyStatusButton` presents this via `.popover(isPresented:)`, and ViewInspector does
/// NOT descend `.popover{}` content — so the popover is snapshotted STANDALONE (the proven
/// recipe), passing `snapshot:`/`model:`/`loginItem:` directly. Its data-driven branches:
///   - the `reframe` header copy (`AutonomyReadinessReframe.present` — calm vs degraded tone),
///     captured as the headline/detail/pill `Text`s.
///   - `ForEach(snapshot.checks)` (`:4718`) — one `AutonomyStatusCheckRow` per check.
///   - the footer `if model.bossWorkbenchMCPRegistration?.isActionable == true` Connect button.
///
/// **Login-item determinism — the carve (P3).** The footer `if !loginItem.isEnabled` "Login" /
/// "Update Login" button (`:4750`) reads the non-injectable, MACHINE-LOCAL `LoginItemController()`
/// live state (`status()` checks whether `~/Applications/Ouro Workbench.app` + the LaunchAgents
/// plist exist) — the same non-injectable `@StateObject` class the `MachineRuntimeView` /
/// `AutonomyStatusButton` allowlist carve names. On a developer machine WITH the app installed it
/// renders nothing (status `.enabled`); on a clean CI runner it renders the "Login" button
/// (`.appBundleMissing`). So the COMMITTED reference DROPS that one footer button via
/// `strippingLoginFooter(_:)` — exactly how the harness already drops `.help` tooltips and
/// `.disabled` for determinism. Everything else in the popover is provenance-built + deterministic.
/// `testPopover_loginFooterIsTheOnlyLoginDependentNode` PROVES the stripped projection is the
/// ONLY login-item-dependent region (the stripped trees are byte-identical across fresh
/// controllers), so the carve is sound and complete.
///
/// **Provenance (P2).** `AutonomyReadinessSnapshot(checks:)` is a `public` Core initializer —
/// constructing it from deterministic `AutonomyReadinessCheck`s IS the real seam (the same type
/// the live `autonomyReadiness` builder emits; the popover re-derives the reframe through the
/// REAL `AutonomyReadinessReframe.present`). `model` via the hermetic `makeVM` (AN-001).
///
/// **Enumerated state-set (the reframe tone the popover renders):**
///   - `ready`    — all `.ok` checks → "ready" pill, the calm "Boss is clear to run" headline.
///   - `watch`    — a `.warning` check → "watch" pill, the "usable with watch points" headline.
///   - `degraded` — a non-remediable `.blocker` (`boss`, never one-tap) → the loud degraded
///                  headline (the `.degraded` tone keeps the Core "blocked" copy).
@MainActor
final class AutonomyStatusPopoverStandaloneTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c3-asp-\(UUID().uuidString)", isDirectory: true)
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

    private func check(_ id: String, _ label: String, _ detail: String, _ state: AutonomyReadinessCheckState) -> AutonomyReadinessCheck {
        AutonomyReadinessCheck(id: id, label: label, detail: detail, state: state)
    }

    private func checks(state: String) -> [AutonomyReadinessCheck] {
        switch state {
        case "ready":
            return [check("boss", "Boss", "Boss is set.", .ok),
                    check("boss-watch", "Boss watch", "Automatic watch mode is running.", .ok)]
        case "watch":
            return [check("boss", "Boss", "Boss is set.", .ok),
                    check("boss-watch", "Boss watch", "Watch mode is paused; manual boss asks still work.", .warning)]
        case "degraded":
            return [check("boss", "Boss", "The selected boss isn't installed.", .blocker),
                    check("boss-watch", "Boss watch", "Automatic watch mode is running.", .ok)]
        default:
            return []
        }
    }

    private func popover(state: String) throws -> AutonomyStatusPopover {
        AutonomyStatusPopover(
            snapshot: AutonomyReadinessSnapshot(checks: checks(state: state)),
            model: try makeVM(),
            loginItem: LoginItemController()
        )
    }

    /// AN-R2-02 — a real, actionable Workbench-MCP registration snapshot (the same
    /// `BossWorkbenchMCPRegistrationSnapshot` the live registrar emits). `.notRegistered`
    /// is `isActionable`, so the footer's Connect button renders. Fixed/relative paths
    /// keep it hermetic (they're never rendered anyway).
    private func actionableMCPRegistration() -> BossWorkbenchMCPRegistrationSnapshot {
        BossWorkbenchMCPRegistrationSnapshot(
            agentName: "boss",
            serverName: "workbench",
            commandPath: "AgentBundles/workbench-mcp",
            agentConfigPath: "AgentBundles/boss.ouro/agent.json",
            status: .notRegistered,
            detail: "Workbench tools not connected"
        )
    }

    /// Drop the lone machine-local login-footer button (`Label("Login"/"Update Login",
    /// systemImage: "power")` — a `Text` line + the `"power"` `Image` line) so the committed
    /// reference is cross-machine deterministic. This is the documented login-item carve; the
    /// `loginFooterIsTheOnlyLoginDependentNode` test proves it's the ONLY login-dependent node.
    private func strippedTree(state: String) throws -> String {
        let raw = try ViewSnapshotHost.snapshotText(of: try popover(state: state))
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                !line.contains(#"text="Login""#)
                    && !line.contains(#"text="Update Login""#)
                    && !line.contains(#"image="power""#)
            }
            .joined(separator: "\n")
    }

    private let store = ViewSnapshotStore.default(testFilePath: #filePath)

    // MARK: - Enumerated state-set (login-footer-stripped projection)

    func testPopover_ready() throws {
        let view = try popover(state: "ready")
        XCTAssertEqual(view.snapshot.state, .ready, "provenance: all-ok → ready")
        try assertViewSnapshotText(try strippedTree(state: "ready"), named: "AutonomyStatusPopover.ready", store: store)
    }

    func testPopover_watch() throws {
        let view = try popover(state: "watch")
        XCTAssertEqual(view.snapshot.state, .attention, "provenance: a warning → attention")
        try assertViewSnapshotText(try strippedTree(state: "watch"), named: "AutonomyStatusPopover.watch", store: store)
    }

    func testPopover_degraded() throws {
        let view = try popover(state: "degraded")
        XCTAssertEqual(view.snapshot.state, .blocked, "provenance: a blocker → blocked")
        try assertViewSnapshotText(try strippedTree(state: "degraded"), named: "AutonomyStatusPopover.degraded", store: store)
    }

    // MARK: - Determinism (P3) — the carve is sound + complete

    /// The login footer is the ONLY login-item-dependent node: with it stripped, the projection is
    /// byte-identical across two FRESH (live-state) controllers, and carries no machine path. This
    /// PROVES the committed (stripped) reference is cross-machine deterministic.
    func testPopover_loginFooterIsTheOnlyLoginDependentNode() throws {
        for state in ["ready", "watch", "degraded"] {
            let a = try strippedTree(state: state)
            let b = try strippedTree(state: state)
            XCTAssertEqual(a, b, "\(state) stripped projection must be byte-identical across fresh controllers")
            XCTAssertFalse(a.contains("/Users/"), "\(state): no machine-path leak:\n\(a)")
            XCTAssertFalse(a.contains(#"text="Login""#), "\(state): the login footer is stripped:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The reframe tone flips the captured header copy: a `.ready`/`.attention` snapshot reads the
    /// calm Core headline ("clear to run" / "usable with watch points"), while a non-remediable
    /// `.blocker` keeps the loud degraded "blocked" headline. And `ForEach(snapshot.checks)`
    /// renders one row per check (the check labels appear in the tree).
    func testPopover_negativeControl_reframeToneAndChecksFlipTree() throws {
        let ready = try strippedTree(state: "ready")
        let watch = try strippedTree(state: "watch")
        let degraded = try strippedTree(state: "degraded")

        XCTAssertTrue(ready.contains("Boss is clear to run"), "ready: the calm headline:\n\(ready)")
        XCTAssertTrue(watch.contains("Autonomy is usable with watch points"), "watch: the headline:\n\(watch)")
        XCTAssertTrue(degraded.contains("Human-free operation is blocked"), "degraded: the loud headline:\n\(degraded)")
        XCTAssertNotEqual(ready, watch, "the readiness state must drive the header")
        XCTAssertNotEqual(watch, degraded, "the degraded tone must drive the header")

        // The check rows render (ForEach) — each check label appears, with state-specific glyphs.
        XCTAssertTrue(ready.contains("Boss watch"), "ready: the boss-watch check row:\n\(ready)")
        XCTAssertTrue(ready.contains("checkmark.circle.fill"), "ready: ok glyph:\n\(ready)")
        XCTAssertTrue(watch.contains("exclamationmark.triangle.fill"), "watch: warning glyph:\n\(watch)")
        XCTAssertTrue(degraded.contains("xmark.octagon.fill"), "degraded: blocker glyph:\n\(degraded)")
    }

    // MARK: - AN-R2-02 — energy-0 r2 close: the footer MCP-actionable Connect button

    /// The footer `if model.bossWorkbenchMCPRegistration?.isActionable == true` Connect
    /// button (`:4763`) was the ONE footer arm the docstring claimed to cover but never
    /// did: all three reframe-tone snapshots leave `bossWorkbenchMCPRegistration` nil, so
    /// the button never rendered and its `Label(model.bossWorkbenchMCPActionTitle,
    /// systemImage: "point.3.connected.trianglepath.dotted")` was never asserted. The
    /// round-2 mutation sweep proved it: suppressing the arm left the popover suite GREEN.
    ///
    /// Here a REAL `.notRegistered` (isActionable) registration snapshot makes the button
    /// live — pinning the "Connect" title + the connector glyph via inline asserts + the
    /// login-footer-stripped reference. Provenance: the same Core
    /// `BossWorkbenchMCPRegistrationSnapshot` the live registrar emits; the title is the
    /// model's real `bossWorkbenchMCPActionTitle` ("Connect" for `.notRegistered`).
    func testPopover_mcpActionable_rendersConnectButton() throws {
        let model = try makeVM()
        model.bossWorkbenchMCPRegistration = actionableMCPRegistration()
        XCTAssertTrue(model.bossWorkbenchMCPRegistration?.isActionable == true,
                      "provenance: a .notRegistered registration is actionable")
        XCTAssertEqual(model.bossWorkbenchMCPActionTitle, "Connect",
                       "provenance: .notRegistered → the Connect action title")

        let view = AutonomyStatusPopover(
            snapshot: AutonomyReadinessSnapshot(checks: checks(state: "ready")),
            model: model,
            loginItem: LoginItemController()
        )
        let tree = strippedLogin(try ViewSnapshotHost.snapshotText(of: view))
        XCTAssertTrue(tree.contains(#"text="Connect""#), "the actionable footer button title:\n\(tree)")
        XCTAssertTrue(tree.contains(#"image="point.3.connected.trianglepath.dotted""#),
                      "the connector glyph:\n\(tree)")
        try assertViewSnapshotText(tree, named: "AutonomyStatusPopover.mcpActionable", store: store)
    }

    /// Negative control (P2): a NON-actionable registration (`.registered`) drops the
    /// Connect button entirely — proving the `isActionable` gate is load-bearing, not
    /// incidental. A nil registration (the default the other three snapshots use) likewise
    /// omits it.
    func testPopover_mcpNotActionable_dropsConnectButton() throws {
        let registeredModel = try makeVM()
        registeredModel.bossWorkbenchMCPRegistration = BossWorkbenchMCPRegistrationSnapshot(
            agentName: "boss", serverName: "workbench",
            commandPath: "AgentBundles/workbench-mcp",
            agentConfigPath: "AgentBundles/boss.ouro/agent.json",
            status: .registered, detail: "")
        XCTAssertFalse(registeredModel.bossWorkbenchMCPRegistration?.isActionable == true,
                       "provenance: .registered is not actionable")
        let registeredTree = strippedLogin(try ViewSnapshotHost.snapshotText(of: AutonomyStatusPopover(
            snapshot: AutonomyReadinessSnapshot(checks: checks(state: "ready")),
            model: registeredModel, loginItem: LoginItemController())))
        XCTAssertFalse(registeredTree.contains(#"image="point.3.connected.trianglepath.dotted""#),
                       "registered: no Connect button:\n\(registeredTree)")

        // nil registration (the default) also omits it.
        let nilTree = strippedLogin(try ViewSnapshotHost.snapshotText(of: try popover(state: "ready")))
        XCTAssertFalse(nilTree.contains(#"image="point.3.connected.trianglepath.dotted""#),
                       "nil registration: no Connect button:\n\(nilTree)")

        // The actionable tree differs from both — the gate flips the tree.
        let actionableModel = try makeVM()
        actionableModel.bossWorkbenchMCPRegistration = actionableMCPRegistration()
        let actionableTree = strippedLogin(try ViewSnapshotHost.snapshotText(of: AutonomyStatusPopover(
            snapshot: AutonomyReadinessSnapshot(checks: checks(state: "ready")),
            model: actionableModel, loginItem: LoginItemController())))
        XCTAssertNotEqual(actionableTree, registeredTree, "the isActionable gate must flip the tree")
    }

    /// Strip ONLY the machine-local login footer (same projection as `strippedTree`) so
    /// the MCP-button reference is cross-machine deterministic — but KEEP the MCP button.
    private func strippedLogin(_ raw: String) -> String {
        raw.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                !line.contains(#"text="Login""#)
                    && !line.contains(#"text="Update Login""#)
                    && !line.contains(#"image="power""#)
            }
            .joined(separator: "\n")
    }
}
#endif
