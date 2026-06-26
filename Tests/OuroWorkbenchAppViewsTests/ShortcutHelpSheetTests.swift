#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C4-1 — `ShortcutHelpSheet` (`:1689`) enumerated state-set.
///
/// The sheet renders the keyboard map via `ForEach(groups)` over
/// `WorkbenchGuide.shortcutCategories` (`:1696`), and `ForEach(group.shortcuts)`
/// per category — each row a `Text(row.keys)` + `Text(row.summary)`. There is no
/// model/data seam (the categories are a single static source of truth, the
/// anti-drift catalogue), so the view is a pure render of that catalogue: the
/// SINGLE deterministic state is "the full shortcut map". It is NOT branchless —
/// the two nested `ForEach`es fan the catalogue's rows into a deep, content-bearing
/// node tree (every category title + every shortcut key/summary is a captured
/// `Text`); a row added to / removed from the catalogue flips the serialized tree.
///
/// **Provenance (P2).** No fixture is built — the catalogue IS the real seam
/// (`WorkbenchGuide.shortcutCategories`, the same const the view reads + the boss
/// `workbench_sense` + the agent context file render). The provenance assertions
/// below confirm the rendered tree carries the REAL catalogue content (specific
/// category titles + a specific shortcut row), not a fabricated stand-in.
///
/// **Determinism (P3).** No clock / path / machine value — the catalogue is a
/// compile-time constant of ASCII glyph strings; the only host concern is the
/// `en_US_POSIX` locale pin (already applied by the host), so the tree is
/// byte-identical twice. Recorded once.
///
/// **Non-vacuity (P2 — the brief's reconfirm bar).** The negative control proves
/// the `ForEach` fan-out is real LOGIC, not vacuous green: the rendered tree
/// carries the catalogue's row data (a named shortcut's keys + summary), and the
/// number of captured rows tracks the catalogue size — if the catalogue produced
/// no rows the tree would lose them.
@MainActor
final class ShortcutHelpSheetTests: XCTestCase {

    // MARK: - Enumerated state-set (the single static render)

    func testShortcutHelp_fullMap() throws {
        // Provenance: the view reads the SAME catalogue these assertions read.
        let categories = WorkbenchGuide.shortcutCategories
        XCTAssertFalse(categories.isEmpty, "provenance: the real catalogue is non-empty")
        XCTAssertTrue(categories.contains { $0.title == "Navigate" },
                      "provenance: the real 'Navigate' category exists")
        XCTAssertTrue(
            categories.flatMap(\.shortcuts).contains { $0.keys == "⌘K" },
            "provenance: the real ⌘K command-palette shortcut exists in the catalogue")

        try assertViewSnapshot(of: ShortcutHelpSheet(), named: "ShortcutHelpSheet.fullMap")
    }

    // MARK: - Determinism (P3)

    func testShortcutHelp_determinism_byteIdenticalTwiceNoLeak() throws {
        let a = try ViewSnapshotHost.snapshotText(of: ShortcutHelpSheet())
        let b = try ViewSnapshotHost.snapshotText(of: ShortcutHelpSheet())
        XCTAssertEqual(a, b, "the static shortcut map must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
    }

    // MARK: - Non-vacuity (P2 — the rendered tree carries the real catalogue rows)

    /// The two nested `ForEach`es are real LOGIC: the captured tree carries the
    /// catalogue's row content. We prove non-vacuity by confirming a named
    /// shortcut's keys AND summary both reach the rendered tree, and that the
    /// header chrome renders — content that vanishes if the catalogue produced
    /// no rows (the fan-out being vacuous).
    func testShortcutHelp_nonVacuity_catalogueRowsReachTree() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: ShortcutHelpSheet())

        // The header chrome (always present).
        XCTAssertTrue(tree.contains("Keyboard Shortcuts"), "the sheet title renders:\n\(tree)")
        // Real catalogue category titles fan in via ForEach(groups).
        XCTAssertTrue(tree.contains("Navigate"), "the Navigate category title renders:\n\(tree)")
        XCTAssertTrue(tree.contains("Boss + Agents"), "the Boss+Agents category title renders")
        // A specific shortcut row (keys + summary) fans in via ForEach(shortcuts) —
        // the deepest node the fan-out produces.
        XCTAssertTrue(tree.contains("⌘K"), "the ⌘K shortcut keys render:\n\(tree)")
        XCTAssertTrue(tree.contains("Open the command palette"),
                      "the ⌘K shortcut summary renders:\n\(tree)")

        // The fan-out count is real: every catalogue row's keys appear in the tree.
        let allKeys = WorkbenchGuide.shortcutCategories.flatMap(\.shortcuts).map(\.keys)
        XCTAssertGreaterThan(allKeys.count, 10, "the catalogue has many rows (a real fan-out)")
        for keys in allKeys {
            XCTAssertTrue(tree.contains(keys),
                          "every catalogue shortcut's keys reach the rendered tree (\(keys))")
        }
    }
}
#endif
