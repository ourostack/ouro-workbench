#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C1 — `SidebarCountBadge` (`:3558`). Listed as a STARRED branchless-reconfirm candidate in
/// the classification; re-confirmed at execution against the host whitelist:
///
///   body = `Text("\(count)")` + `.accessibilityLabel("\(count) active terminals")`.
///
/// The `count` input flips BOTH a CAPTURED `Text` node value AND a CAPTURED a11y label — both
/// are on `ViewSnapshotHost.mapNode`'s whitelist (Text string + a11y label). So a different
/// `count` changes the serialized node tree → it is LOGIC-BEARING by the rubric's own test (a
/// value-flip in a captured node, exactly like `GitBranchChip`'s branch label), NOT branchless.
/// It STAYS in C1 (covered here), and is removed from the deferred set in the C1 iteration log.
/// (Contrast `WorkspaceTabContextMenu` — re-confirmed GENUINELY branchless and DROPPED: its
/// only content is the CONSTANT `Label("Rename Tab…  ⌘R")`; `tab` feeds only the action closure,
/// never a captured node.)
///
/// **Provenance (P2).** `SidebarCountBadge` is a pure value leaf whose ONLY input is the `Int`
/// count; instantiating it with a deterministic count IS the seam (no model/producer exists —
/// the live caller passes `model.terminalCount(in:)`, a plain `Int`). The badge is instantiated
/// via its own `View` initializer (the leaf seam).
///
/// **Determinism (P3).** Integer counts only — no clock/path/UUID; byte-identical twice;
/// `!contains("/Users/")`.
///
/// **Enumerated state-set (the captured value-flip):**
///   - `zero`  — `count == 0` → "0" + "0 active terminals".
///   - `one`   — `count == 1` → "1" + "1 active terminals".
///   - `many`  — `count == 42` → "42" + "42 active terminals".
@MainActor
final class SidebarCountBadgeTests: XCTestCase {

    // MARK: - Enumerated state-set (the captured value flips)

    func testBadge_zero() throws {
        let view = SidebarCountBadge(count: 0)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="0""#), "the count renders:\n\(tree)")
        XCTAssertTrue(tree.contains("0 active terminals"), "the a11y read:\n\(tree)")
        try assertViewSnapshot(of: view, named: "SidebarCountBadge.zero")
    }

    func testBadge_one() throws {
        let view = SidebarCountBadge(count: 1)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="1""#), "the count renders:\n\(tree)")
        try assertViewSnapshot(of: view, named: "SidebarCountBadge.one")
    }

    func testBadge_many() throws {
        let view = SidebarCountBadge(count: 42)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="42""#), "the count renders:\n\(tree)")
        XCTAssertTrue(tree.contains("42 active terminals"), "the a11y read:\n\(tree)")
        try assertViewSnapshot(of: view, named: "SidebarCountBadge.many")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The `count` drives the captured `Text` value + a11y label — a different count changes
    /// the tree (the value-flip that makes this logic-bearing, not branchless).
    func testBadge_negativeControl_countFlipsTree() throws {
        let zero = try ViewSnapshotHost.snapshotText(of: SidebarCountBadge(count: 0))
        let one = try ViewSnapshotHost.snapshotText(of: SidebarCountBadge(count: 1))
        let many = try ViewSnapshotHost.snapshotText(of: SidebarCountBadge(count: 42))

        XCTAssertNotEqual(zero, one, "the count must drive the captured Text value")
        XCTAssertNotEqual(one, many, "the count must drive the captured Text value")
        XCTAssertTrue(zero.contains(#"text="0""#) && one.contains(#"text="1""#) && many.contains(#"text="42""#),
                      "each count renders its own value:\n\(zero)\n\(one)\n\(many)")
    }

    // MARK: - Determinism (P3)

    func testBadge_determinism_byteIdenticalTwiceAndNoLeak() throws {
        for count in [0, 1, 42] {
            let a = try ViewSnapshotHost.snapshotText(of: SidebarCountBadge(count: count))
            let b = try ViewSnapshotHost.snapshotText(of: SidebarCountBadge(count: count))
            XCTAssertEqual(a, b, "count=\(count) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "count=\(count): no machine-path leak:\n\(a)")
        }
    }
}
#endif
