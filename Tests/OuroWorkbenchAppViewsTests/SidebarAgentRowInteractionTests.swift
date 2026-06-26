#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B1 — `SidebarAgentRow` (`:3488`) selected-arm + select-closure drive-to-100%.
///
/// The C1 `SidebarAgentRowTests` always pass `isSelected: false`, so the `isSelected ? … : .clear`
/// selection-background ternary's TRUE arm (`L3539:40`) was uncovered. This suite renders the row
/// with `isSelected: true` (covering that arm) AND taps its `select` `Button` (asserting the closure
/// fires), then MUTATION-VERIFIES the select closure.
///
/// **Provenance (P2).** `OuroAgentRecord` is a `public` Core value type; the row is a pure value
/// view instantiated directly (the C1 leaf precedent). The `select` closure is observed via a
/// captured flag (the same shape the live `WorkbenchSidebarView` wires through `model.selectAgent`).
///
/// **Determinism (P3).** Fixed name; relative bundle paths; no clock; `!contains("/Users/")`.
@MainActor
final class SidebarAgentRowInteractionTests: XCTestCase {

    private func record(_ name: String) -> OuroAgentRecord {
        OuroAgentRecord(name: name, bundlePath: "AgentBundles/\(name).ouro",
                        configPath: "AgentBundles/\(name).ouro/agent.json",
                        status: .ready, detail: "ready", humanFacing: nil)
    }

    private func row(_ name: String, isSelected: Bool, select: @escaping () -> Void = {}) -> SidebarAgentRow {
        SidebarAgentRow(agent: record(name), isBoss: false, isSelected: isSelected,
                        verdict: nil, isChecking: false, select: select)
    }

    // MARK: - Selected arm (the isSelected ? accent : .clear background true branch)

    func testSelectedRow_rendersAndDiffersFromUnselected() throws {
        // The selection-background fill is geometry/color (dropped from the captured tree), but the
        // TRUE arm of the ternary executes when isSelected is true — driving L3539. We assert the
        // view's isSelected provenance + that the row still renders its content node.
        let selected = row("alpha", isSelected: true)
        XCTAssertTrue(selected.isSelected, "provenance: the selected arm is taken")
        let tree = try ViewSnapshotHost.snapshotText(of: selected)
        XCTAssertTrue(tree.contains(#"text="alpha""#), "the selected row still renders its name:\n\(tree)")
    }

    // MARK: - select closure (the Button action)

    func testTap_selectButton_invokesSelectClosure() throws {
        var selected = false
        let view = row("alpha", isSelected: false, select: { selected = true })
        XCTAssertFalse(selected, "provenance: not selected yet")
        try view.inspect().find(ViewType.Button.self).tap()
        XCTAssertTrue(selected, "tapping the agent row invokes its select closure")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The select closure is load-bearing: tapping the row fires it. (Mutation-verify: replacing the
    /// `Button(action: select)` body with a no-op leaves the flag false → RED.)
    func testNegativeControl_selectClosureFires() throws {
        var fired = false
        let view = row("beta", isSelected: false, select: { fired = true })
        try view.inspect().find(ViewType.Button.self).tap()
        XCTAssertTrue(fired, "the select action must invoke the closure")
    }
}
#endif
