#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 — `HarnessActionRow` (`:1550`) + `OnboardingBossChoiceRow` (`:6879`) drive-to-100%.
///
/// `HarnessActionRow`'s `if isBusy { ProgressView }` render arm and `OnboardingBossChoiceRow`'s
/// boss-pick `Button` action were never executed (both rows are only built inside parents the
/// C-series didn't drive at those states). Promoted private->internal for the per-file-100%
/// gate; this suite renders the busy arm and taps the pick action, asserting the effect.
///
/// **Carves:** none.
@MainActor
final class HarnessActionRowAndBossChoiceDriveTests: XCTestCase {

    private func makeVM(bossName: String = "boss") throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("u5-harnessrow-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: bossName)))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    // MARK: - HarnessActionRow `if isBusy { ProgressView }`

    /// `isBusy == true` renders the in-flight `ProgressView` (the TRUE arm); the action
    /// closure also fires on tap. A negative control (`isBusy == false`) has NO ProgressView.
    func testHarnessActionRow_isBusy_rendersProgressViewAndAction() throws {
        let model = try makeVM()
        var fired = false
        let busy = HarnessActionRow(title: "Bring back online", systemImage: "bolt.heart",
                                    help: "repair", isUrgent: true, isBusy: true, action: { fired = true })
        XCTAssertNoThrow(try busy.inspect().find(ViewType.ProgressView.self),
                         "isBusy == true renders the in-flight ProgressView")
        try busy.inspect().find(button: "Bring back online").tap()
        XCTAssertTrue(fired, "the row's action closure fires on tap")

        let idle = HarnessActionRow(title: "Bring back online", systemImage: "bolt.heart",
                                    help: "repair", isUrgent: false, isBusy: false, action: {})
        XCTAssertThrowsError(try idle.inspect().find(ViewType.ProgressView.self),
                             "isBusy == false renders NO ProgressView (negative control)")
    }

    // MARK: - OnboardingBossChoiceRow boss-pick action

    /// Tapping the choice row runs `model.registerWorkbenchForBossChoice(choice.name)` →
    /// `selectBoss` makes the picked agent the boss (observable in `state.boss.agentName`).
    func testBossChoiceRow_tap_selectsBoss() throws {
        let model = try makeVM(bossName: "old-boss")
        let choice = OnboardingBossChoice(
            name: "new-boss", detail: "installed", status: .ready, isSelected: false)
        XCTAssertEqual(model.state.boss.agentName, "old-boss", "precondition: a different boss")
        try OnboardingBossChoiceRow(choice: choice, model: model)
            .inspect().find(button: "new-boss").tap()
        XCTAssertEqual(model.state.boss.agentName, "new-boss",
                       "picking the row registers + selects the new boss")
    }
}
#endif
