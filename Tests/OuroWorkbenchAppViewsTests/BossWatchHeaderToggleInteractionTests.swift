#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B2 — `BossWatchHeaderToggle` (`:4289`) pill-tap INTERACTION drive-to-100%.
///
/// The toggle's only uncovered region is the pill `Button` action `{ model.setBossWatchEnabled(
/// !model.bossWatchIsEnabled) }` (`:4305`). The pill renders only when `presentation.isVisible`
/// (`currentBossIsUsable` — a `.ready` boss agent), so this provenance-builds a usable boss, renders
/// the pill, FINDS its button and `.tap()`s it → flipping `bossWatchIsEnabled`.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` (AN-001) with boss "boss"; `ouroAgents`
/// injects a `.ready` "boss" record so `currentBossIsUsable == true` → the pill is visible. The pill
/// label/tint come from the pure `BossWatchPresentation.resolve` Core seam.
@MainActor
final class BossWatchHeaderToggleInteractionTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b2-bwt-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        // Persist watch OFF so the first tap flips it ON deterministically.
        var state = WorkspaceState(boss: BossAgentSelection(agentName: "boss"))
        state.bossWatchEnabled = false
        try WorkbenchStore(paths: paths).save(state)
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        // A .ready boss agent → currentBossIsUsable → the pill is visible.
        model.ouroAgents = [OuroAgentRecord(
            name: "boss", bundlePath: "AgentBundles/boss.ouro",
            configPath: "AgentBundles/boss.ouro/agent.json", status: .ready, detail: "ready")]
        return model
    }

    func testToggle_pillTap_flipsWatch() throws {
        let model = try makeVM()
        XCTAssertTrue(model.currentBossIsUsable, "provenance: a usable boss → the pill is visible")
        XCTAssertTrue(model.bossWatchPresentation.isVisible, "provenance: presentation visible")
        XCTAssertFalse(model.bossWatchIsEnabled, "precondition: watch OFF")

        let view = BossWatchHeaderToggle(model: model)
        try view.inspect().find(ViewType.Button.self).tap()
        XCTAssertTrue(model.bossWatchIsEnabled, "tapping the watch pill enables boss watch")
        model.setBossWatchEnabled(false)  // stop the watch loop the toggle started
    }

    /// Negative control (P2): with NO usable boss the pill is hidden (`isVisible == false`), so the
    /// `if presentation.isVisible` gate is load-bearing — a button search finds nothing.
    func testToggle_noUsableBoss_pillHidden() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b2-bwt-hidden-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "")))
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        XCTAssertFalse(model.bossWatchPresentation.isVisible, "provenance: no usable boss → hidden")
        XCTAssertThrowsError(try BossWatchHeaderToggle(model: model).inspect().find(ViewType.Button.self),
                             "the hidden pill renders no button")
    }
}
#endif
