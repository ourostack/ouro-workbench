#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B6 — `CommandPaletteSheet` (`:5032`) INTERACTION drive-to-100%.
///
/// The C4 `CommandPaletteSheetTests` drove the grouped / empty / filtered RENDER arms. This suite
/// closes the residual interaction regions by INVOKING their closures:
///   - **L5093** `.onAppear { model.commandPaletteQuery = ""; selectedIndex = 0; searchFocused = true }`
///     — `callOnAppear()`; effect: `model.commandPaletteQuery` reset to "".
///   - **L5102** `.onDisappear { model.performPendingPaletteCommand() }` — `callOnDisappear()`;
///     effect: a pending command is consumed (set to nil + performed).
///   - **L5098** `.onChange(of: model.commandPaletteQuery)` — `callOnChange`; resets the highlight.
///   - **L5086/L5087** `.onChange(of: selectedIndex)` — `callOnChange`; scrolls the highlighted row.
///   - **L5151** the palette row `Button { run(command) }` — `find(button:).tap()`; effect:
///     `model.pendingPaletteCommand` is set to that command.
///   - **L5184/L5127/L5128/L5186/L5192** `runSelectedCommand()` (via `.onSubmit`) → `visualOrderedItems`
///     → `run(_:)`; BOTH guard arms: non-empty items (guard passes → a command pends) and empty
///     items (guard fails → `return`, nothing pends).
///
/// **CARVES (recorded for Unit 3):**
///   - **L5049/L5050** `.onKeyPress(.downArrow/.upArrow)` — ViewInspector 0.10.3 has NO key-press
///     driver; the closures (`moveSelection(by:); return .handled`) cannot be invoked.
///   - **L5178/L5180** `private func moveSelection(by:)` (+ its `guard count > 0`) — reached ONLY
///     from the two un-invokable `.onKeyPress` closures, so it is unreachable in-process.
///   - **L5120** `SectionedRows.id` getter — vestigial `Identifiable` conformance; `ForEach` uses
///     `id: \.section`, never `.id`, so the getter is never read.
///   - **L5038** `@State private var selectedIndex = 0` — the `State(wrappedValue:)` default-value
///     autoclosure llvm-cov does not count (the documented @State-default artifact).
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` seam; the command list is the model's REAL
/// `commandPaletteItems`/`filteredCommandPaletteItems`. The `run`/`onSubmit` paths set the REAL
/// `pendingPaletteCommand`, the same field the live palette dismiss consumes.
@MainActor
final class CommandPaletteSheetInteractionTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b6-palette-\(UUID().uuidString)", isDirectory: true)
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

    private func palette(_ model: WorkbenchViewModel, query: String = "") -> CommandPaletteSheet {
        model.commandPaletteQuery = query
        return CommandPaletteSheet(model: model)
    }

    // MARK: - L5093 — onAppear resets the query

    func testPalette_onAppear_resetsQuery() throws {
        let model = try makeVM()
        let view = palette(model, query: "stale-query")
        XCTAssertEqual(model.commandPaletteQuery, "stale-query", "provenance: a stale query before appear")
        // The body's `.onAppear`/`.onChange(query)`/`.onDisappear` are on the root VStack.
        try view.inspect().vStack().callOnAppear()
        XCTAssertEqual(model.commandPaletteQuery, "",
                       "onAppear resets commandPaletteQuery to empty")
    }

    // MARK: - L5102 — onDisappear performs the pending command

    func testPalette_onDisappear_performsPendingCommand() throws {
        let model = try makeVM()
        let pending = try XCTUnwrap(model.commandPaletteItems.first, "provenance: a real command exists")
        model.pendingPaletteCommand = pending
        let view = palette(model)
        try view.inspect().vStack().callOnDisappear()
        XCTAssertNil(model.pendingPaletteCommand,
                     "onDisappear consumed the pending command via performPendingPaletteCommand")
    }

    /// Negative control (P2): with NO pending command, onDisappear is a clean no-op (the
    /// `guard let pending` early-return in performPendingPaletteCommand) — it must not crash or set
    /// a command. Pairs with the positive test to prove the disappear closure runs the real path.
    func testPalette_onDisappear_noPending_isNoOp() throws {
        let model = try makeVM()
        XCTAssertNil(model.pendingPaletteCommand, "provenance: nothing pending")
        try palette(model).inspect().vStack().callOnDisappear()
        XCTAssertNil(model.pendingPaletteCommand, "onDisappear with nothing pending stays nil")
    }

    // MARK: - L5098 — onChange(of: commandPaletteQuery)

    func testPalette_onChangeQuery_invokes() throws {
        let model = try makeVM()
        let view = palette(model)
        // Two-param SwiftUI onChange → ViewInspector's callOnChange(oldValue:newValue:). The query
        // onChange is on the root VStack; its body resets the @State highlight (no model effect),
        // so invoking it covers the closure region.
        try view.inspect().vStack().callOnChange(oldValue: "", newValue: "boss")
    }

    // MARK: - L5086 / L5087 — onChange(of: selectedIndex)

    func testPalette_onChangeSelectedIndex_invokes() throws {
        let model = try makeVM()
        let view = palette(model)
        // The Int `selectedIndex` onChange is on the inner ScrollView (inside ScrollViewReader);
        // its body scrolls the highlighted row in a `withAnimation`. Invoking it covers the closure.
        try view.inspect().find(ViewType.ScrollView.self).callOnChange(oldValue: 0, newValue: 1)
    }

    // MARK: - L5151 — the palette row Button sets pendingPaletteCommand

    func testPalette_rowButton_tapSetsPendingCommand() throws {
        let model = try makeVM()
        let view = palette(model, query: "")
        let first = try XCTUnwrap(model.filteredCommandPaletteItems.first, "provenance: a real command")
        // Tap the row whose title is the first command. run(_) sets pendingPaletteCommand then
        // dismisses; the pending field is the observable effect.
        try view.inspect().find(button: first.title).tap()
        XCTAssertEqual(model.pendingPaletteCommand?.id, first.id,
                       "tapping a palette row set pendingPaletteCommand to that command")
    }

    // MARK: - L5184 / L5127 / L5128 / L5186 / L5192 — runSelectedCommand via onSubmit (guard PASSES)

    func testPalette_onSubmit_nonEmpty_runsSelectedCommand() throws {
        let model = try makeVM()
        let view = palette(model, query: "")
        let visualFirst = try XCTUnwrap(
            WorkbenchCommandSection.grouped(model.filteredCommandPaletteItems).flatMap(\.commands).first,
            "provenance: the visual-ordered list is non-empty")
        // selectedIndex re-seeds to 0 under inspect → runSelectedCommand runs items[0] (the visual
        // first). The guard `0 < items.count` passes; run(_) sets pendingPaletteCommand. `.onSubmit`
        // is on the query TextField.
        try view.inspect().find(ViewType.TextField.self).callOnSubmit()
        XCTAssertEqual(model.pendingPaletteCommand?.id, visualFirst.id,
                       "onSubmit ran the selected (index 0) command via runSelectedCommand → run")
    }

    // MARK: - L5188 — runSelectedCommand guard FAILS on an empty filtered list

    func testPalette_onSubmit_empty_guardReturnsNoCommand() throws {
        let model = try makeVM()
        let view = palette(model, query: "zzqqx-no-such-command")
        XCTAssertTrue(model.filteredCommandPaletteItems.isEmpty, "provenance: empty filtered list")
        // selectedIndex 0, items.count 0 → `0 < 0` false → the guard's else `return` (L5188).
        try view.inspect().find(ViewType.TextField.self).callOnSubmit()
        XCTAssertNil(model.pendingPaletteCommand,
                     "onSubmit on an empty list hits the guard return and pends nothing")
    }

    // MARK: - Class 8 — clampedSelection (the ↑/↓ keyboard-nav math), DRIVEN as a pure static fn
    //
    // `moveSelection(by:)` is reached only from the two `.onKeyPress` closures, which ViewInspector
    // 0.10.3 cannot drive. The clamp math is extracted to a behavior-identical
    // `static func clampedSelection(current:delta:count:)`, unit-tested here by value. The
    // `.onKeyPress` BINDINGS themselves remain the genuine floor.

    func testClampedSelection_movesDownWithinBounds() {
        XCTAssertEqual(CommandPaletteSheet.clampedSelection(current: 0, delta: 1, count: 5), 1)
        XCTAssertEqual(CommandPaletteSheet.clampedSelection(current: 2, delta: 1, count: 5), 3)
    }

    func testClampedSelection_movesUpWithinBounds() {
        XCTAssertEqual(CommandPaletteSheet.clampedSelection(current: 3, delta: -1, count: 5), 2)
    }

    func testClampedSelection_clampsAtUpperBound() {
        XCTAssertEqual(CommandPaletteSheet.clampedSelection(current: 4, delta: 1, count: 5), 4,
                       "delta past the end clamps to count-1")
    }

    func testClampedSelection_clampsAtLowerBound() {
        XCTAssertEqual(CommandPaletteSheet.clampedSelection(current: 0, delta: -1, count: 5), 0,
                       "delta below 0 clamps to 0")
    }

    func testClampedSelection_emptyListReturnsCurrentUnchanged() {
        XCTAssertEqual(CommandPaletteSheet.clampedSelection(current: 0, delta: 1, count: 0), 0,
                       "an empty list is a no-op (the guard returns current)")
    }
}
#endif
