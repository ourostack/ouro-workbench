#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B2 — `AutonomyStatusButton` (`:4572`) drive-the-non-login-arms (K1 PARTIAL split, D9).
///
/// The C3 `AutonomyStatusButtonTests` covered ONLY the no-boss neutral arm. Per D9 the partial carve
/// is split per-arm: the genuinely-untestable login-tainted arms stay carves, the rest are DRIVEN here.
///
/// **DRIVEN (non-login):**
///   - the `pillTint` `.real` arm (`:4596`): a BOSS-SET model takes the `HeaderCalmPresentation`
///     `.real` style, so `pillTint` evaluates `snapshot.state.tint` (the arm region runs). [The
///     resulting TINT VALUE folds the login check, so its byte value is not asserted — only that the
///     arm executes; the no-boss test pins the `.neutral` value arm.]
///   - the button action `{ loginItem.refresh(); isPresented.toggle() }` (`:4635`) via `.tap()`.
///   - `.onAppear { loginItem.refresh() }` (`:4665`) via `callOnAppear()`.
///
/// **CARVE (recorded for Unit 3 — non-injectable `LoginItemController`):**
///   - the three `loginItemCheck` arms the live machine does NOT report (`:4610`/`:4617`/`:4624`):
///     `LoginItemController.status` is `@Published private(set)`, read from the live
///     `LaunchAgentLoginItem.defaultAppURL()` at `init()` with no injection seam, so only the ONE
///     case the runner's machine actually reports executes; the other three are unreachable in-process.
///   - the `.popover` content closure (`:4656`): ViewInspector does NOT descend `.popover{}` — the
///     content (`AutonomyStatusPopover`) is covered STANDALONE in its own suite.
///   - the `@StateObject loginItem`/`@State isPresented` default-value initializers (`:4574`/`:4575`):
///     property-wrapper storage initializers with no app seam (the StateObject is the login carve).
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` (AN-001) with a BOSS SET (the `.real` arm).
@MainActor
final class AutonomyStatusButtonInteractionTests: XCTestCase {

    private func makeVM(bossName: String) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b2-asb-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(
            WorkspaceState(boss: BossAgentSelection(agentName: bossName)))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    /// The boss-set `.real` pillTint arm: rendering a boss-set button evaluates the `.real` branch of
    /// `pillTint` (the previously-uncovered arm). The neutral no-boss arm is the C3 value test; here we
    /// only need the arm to EXECUTE, so we render the body (which reads `pillTint`).
    func testButton_bossSet_realPillTintArm() throws {
        let model = try makeVM(bossName: "boss")
        XCTAssertFalse(model.state.boss.agentName.isEmpty, "provenance: a boss is set → the .real arm")
        // Rendering evaluates the label, which reads pillTint → the .real arm runs.
        let tree = try ViewSnapshotHost.snapshotText(of: AutonomyStatusButton(model: model))
        XCTAssertTrue(tree.contains("TTFA"), "the boss-set pill renders its TTFA text:\n\(tree)")
    }

    /// The button action `{ loginItem.refresh(); isPresented.toggle() }` is driven by `.tap()`. The
    /// observable effect (the `@State isPresented` toggle) is internal; the action region executes.
    func testButton_tap_runsAction() throws {
        let model = try makeVM(bossName: "boss")
        try AutonomyStatusButton(model: model).inspect().find(ViewType.Button.self).tap()
        // No throw: the action ran (loginItem.refresh() + isPresented.toggle()).
    }

    /// `.onAppear { loginItem.refresh() }` is driven by `callOnAppear()`.
    func testButton_onAppear_runs() throws {
        let model = try makeVM(bossName: "boss")
        try AutonomyStatusButton(model: model).inspect().find(ViewType.Button.self).callOnAppear()
    }

    // MARK: - Class 7 — the loginItemCheck switch arms, DRIVEN as a pure static function
    //
    // `loginItemCheck` maps `LaunchAgentLoginItemStatus → AutonomyReadinessCheck`. The view's
    // live `loginItem.status` reports only ONE status, so 3 of the 4 arms were carved. Extracting
    // it to a behavior-identical `static func loginItemCheck(for:)` makes every arm directly
    // unit-testable + mutation-verifiable (each arm's detail + severity is asserted by value).

    func testLoginItemCheck_enabledArm() {
        let check = AutonomyStatusButton.loginItemCheck(for: .enabled)
        XCTAssertEqual(check.id, "open-at-login")
        XCTAssertEqual(check.label, "Open at Login")
        XCTAssertEqual(check.detail, "Workbench will reopen after a computer restart.")
        XCTAssertEqual(check.state, .ok, "enabled → ok")
    }

    func testLoginItemCheck_needsUpdateArm() {
        let check = AutonomyStatusButton.loginItemCheck(for: .needsUpdate)
        XCTAssertEqual(check.detail, "Login item points at a different app bundle and needs an update.")
        XCTAssertEqual(check.state, .warning, "needsUpdate → warning")
    }

    func testLoginItemCheck_notInstalledArm() {
        let check = AutonomyStatusButton.loginItemCheck(for: .notInstalled)
        XCTAssertEqual(check.detail, "Workbench will not reopen automatically after restart.")
        XCTAssertEqual(check.state, .warning, "notInstalled → warning")
    }

    func testLoginItemCheck_appBundleMissingArm() {
        let check = AutonomyStatusButton.loginItemCheck(for: .appBundleMissing)
        XCTAssertEqual(check.detail, "The installed app bundle is missing.")
        XCTAssertEqual(check.state, .blocker, "appBundleMissing → blocker")
    }

    /// Integration: the `init(model:loginItem:)` seam folds the injected controller's check into
    /// the rendered pill — an appBundleMissing controller still renders the boss-set pill (the
    /// body reads the folded snapshot). Drives the seam end-to-end.
    func testButton_injectedController_rendersFoldedPill() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c7asb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let item = LaunchAgentLoginItem(
            appURL: root.appendingPathComponent("missing.app", isDirectory: true), homeURL: root)
        let controller = LoginItemController(loginItem: item)
        XCTAssertEqual(controller.status, .appBundleMissing, "provenance: injected appBundleMissing")
        let tree = try ViewSnapshotHost.snapshotText(
            of: AutonomyStatusButton(model: try makeVM(bossName: "boss"), loginItem: controller))
        XCTAssertTrue(tree.contains("TTFA"), "the pill renders with the injected check folded in:\n\(tree)")
    }
}
#endif
