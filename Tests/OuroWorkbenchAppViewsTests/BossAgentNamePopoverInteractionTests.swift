#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B2 — `BossAgentNamePopover` (`:4482`) STANDALONE interaction drive-to-100%.
///
/// `BossSelectorView` presents this via `.popover`, which ViewInspector does NOT descend — so the
/// popover is driven STANDALONE (the proven recipe), passing its `@Binding`s directly via a boxed
/// reference. The 7 uncovered regions are all action/closure regions:
///   - `.onSubmit(apply)` (`:4504`), the "Cancel" button (`isPresented = false`), the "Use" button
///     (`apply()`), `.onAppear { fieldIsFocused = true }` (`:4522`), and the `apply()` function with
///     its two arms — the `guard canApply else { return }` invalid-name arm and the success arm
///     (`selectBoss` + `isPresented = false`).
/// This suite invokes each via ViewInspector (`callOnAppear`, `find(button:).tap()`, `callOnSubmit`)
/// and asserts the side-effect; the invalid-vs-valid name drives both `apply` arms.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` (AN-001). The bindings are real `Binding`s
/// over a boxed `(agentName, isPresented)` so tapping mutates observable state. `canApply` is the
/// REAL `BossWorkbenchMCPRegistrar.isValidAgentBundleName` Core seam.
@MainActor
final class BossAgentNamePopoverInteractionTests: XCTestCase {

    /// A reference box so the popover's `@Binding`s mutate observable test state.
    private final class Box {
        var agentName: String
        var isPresented: Bool
        init(agentName: String, isPresented: Bool) {
            self.agentName = agentName
            self.isPresented = isPresented
        }
    }

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b2-banp-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(
            WorkspaceState(boss: BossAgentSelection(agentName: "old-boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    private func popover(_ box: Box, model: WorkbenchViewModel) -> BossAgentNamePopover {
        BossAgentNamePopover(
            agentName: Binding(get: { box.agentName }, set: { box.agentName = $0 }),
            isPresented: Binding(get: { box.isPresented }, set: { box.isPresented = $0 }),
            model: model)
    }

    // MARK: - onAppear

    func testPopover_onAppear_runs() throws {
        let box = Box(agentName: "", isPresented: true)
        let view = popover(box, model: try makeVM())
        // The .onAppear sets the @FocusState; ViewInspector invokes it (no throw covers the region).
        try view.inspect().vStack().callOnAppear()
    }

    // MARK: - Cancel button

    func testPopover_cancel_dismisses() throws {
        let box = Box(agentName: "new-boss", isPresented: true)
        let view = popover(box, model: try makeVM())
        try view.inspect().find(button: "Cancel").tap()
        XCTAssertFalse(box.isPresented, "Cancel dismisses the popover")
    }

    // MARK: - Use button (the apply() success arm)

    func testPopover_use_validName_selectsBossAndDismisses() throws {
        let model = try makeVM()
        let box = Box(agentName: "new-boss", isPresented: true)
        XCTAssertEqual(model.state.boss.agentName, "old-boss", "precondition")
        try popover(box, model: model).inspect().find(button: "Use").tap()
        XCTAssertEqual(model.state.boss.agentName, "new-boss", "Use selects the typed boss")
        XCTAssertFalse(box.isPresented, "Use dismisses on success")
    }

    // MARK: - apply() invalid-name guard arm (.onSubmit path)

    /// An INVALID name (a slash) makes `canApply == false`; the "Use" button is `.disabled(!canApply)`
    /// so we drive the `apply()` guard-fail arm via `.onSubmit` instead. The guard returns early:
    /// the boss is unchanged and the popover stays open.
    func testPopover_onSubmit_invalidName_guardReturns() throws {
        let model = try makeVM()
        let box = Box(agentName: "bad/name", isPresented: true)
        try popover(box, model: model).inspect().find(ViewType.TextField.self).callOnSubmit()
        XCTAssertEqual(model.state.boss.agentName, "old-boss", "invalid name → apply guard returns, boss unchanged")
        XCTAssertTrue(box.isPresented, "invalid name → still open")
    }

    /// A VALID name submitted via `.onSubmit(apply)` selects the boss and dismisses (the success arm
    /// reached through the submit path, not the button).
    func testPopover_onSubmit_validName_applies() throws {
        let model = try makeVM()
        let box = Box(agentName: "fresh-boss", isPresented: true)
        try popover(box, model: model).inspect().find(ViewType.TextField.self).callOnSubmit()
        XCTAssertEqual(model.state.boss.agentName, "fresh-boss", "valid submit selects the boss")
        XCTAssertFalse(box.isPresented, "valid submit dismisses")
    }

    // MARK: - the invalid-name warning Text arm

    /// `if !trimmedAgentName.isEmpty && !canApply` renders the red warning Text — driven by a
    /// non-empty invalid name.
    func testPopover_invalidName_rendersWarning() throws {
        let box = Box(agentName: "bad/name", isPresented: true)
        let tree = try ViewSnapshotHost.snapshotText(of: popover(box, model: try makeVM()))
        XCTAssertTrue(tree.contains("That name can't be used"), "the invalid-name warning renders:\n\(tree)")
        // A valid name omits the warning.
        let okBox = Box(agentName: "good-name", isPresented: true)
        let okTree = try ViewSnapshotHost.snapshotText(of: popover(okBox, model: try makeVM()))
        XCTAssertFalse(okTree.contains("That name can't be used"), "valid name → no warning:\n\(okTree)")
    }
}
#endif
