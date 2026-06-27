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

    /// `isBusy == true` renders the in-flight `ProgressView` (the TRUE arm) AND disables the
    /// button (`.disabled(isBusy)`). `isBusy == false` renders NO ProgressView and the action
    /// fires on tap. Drives both arms of `if isBusy`, both `.disabled(isBusy)` states, and the
    /// action closure (via the enabled row — ViewInspector refuses to tap a disabled button).
    func testHarnessActionRow_isBusyArm_andEnabledAction() throws {
        // Busy: the ProgressView arm renders; the button is disabled (can't tap).
        let busy = HarnessActionRow(title: "Bring back online", systemImage: "bolt.heart",
                                    help: "repair", isUrgent: true, isBusy: true, action: {})
        XCTAssertNoThrow(try busy.inspect().find(ViewType.ProgressView.self),
                         "isBusy == true renders the in-flight ProgressView")

        // Idle: NO ProgressView, button enabled → the action closure fires on tap (urgent arm).
        var fired = false
        let idleUrgent = HarnessActionRow(title: "Bring back online", systemImage: "bolt.heart",
                                          help: "repair", isUrgent: true, isBusy: false, action: { fired = true })
        XCTAssertThrowsError(try idleUrgent.inspect().find(ViewType.ProgressView.self),
                             "isBusy == false renders NO ProgressView (negative control)")
        try idleUrgent.inspect().find(button: "Bring back online").tap()
        XCTAssertTrue(fired, "the enabled row's action closure fires on tap")

        // The non-urgent button-style arm also renders + taps (the `else` of `if isUrgent`).
        var firedQuiet = false
        let idleQuiet = HarnessActionRow(title: "Connect tools", systemImage: "link",
                                         help: "connect", isUrgent: false, isBusy: false, action: { firedQuiet = true })
        try idleQuiet.inspect().find(button: "Connect tools").tap()
        XCTAssertTrue(firedQuiet, "the non-urgent (bordered) row's action also fires")
    }

    // MARK: - OnboardingBossChoiceRow boss-pick action

    /// Tapping the choice row runs `model.registerWorkbenchForBossChoice(choice.name)` →
    /// `selectBoss` makes the picked agent the boss (observable in `state.boss.agentName`).
    func testBossChoiceRow_tap_selectsBoss() throws {
        let model = try makeVM(bossName: "old-boss")
        let choice = OnboardingBossChoice(
            name: "new-boss", detail: "installed", status: .ready, isSelected: false)
        XCTAssertEqual(model.state.boss.agentName, "old-boss", "precondition: a different boss")
        // The whole row is a single Button (its label is an HStack with Text(choice.name));
        // tap the only Button rather than match a nested text via find(button:).
        try OnboardingBossChoiceRow(choice: choice, model: model)
            .inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(model.state.boss.agentName, "new-boss",
                       "picking the row registers + selects the new boss")
    }
}
#endif
