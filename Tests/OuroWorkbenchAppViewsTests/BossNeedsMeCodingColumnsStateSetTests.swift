#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C2-5 — `BossNeedsMeCodingColumns` (#U23c — the boss pane's actionable "Needs Me" /
/// "Coding" columns). LOGIC, high-fan-out: it flips on the outer
/// `if !needsMeItems.isEmpty || !codingItems.isEmpty` (the whole view self-hides when
/// both are empty), on each column's own `if !…isEmpty`, on `ForEach(prefix(visibleCount))`,
/// and on `if let viewAll = presentation.viewAllLabel` (the "View all N" overflow control
/// that replaces silent `prefix(3)` truncation). Each flips CAPTURED `Text` nodes.
///
/// **Provenance (P2).** The `BossDashboardSnapshot` is provenance-built through the REAL
/// producer — `BossDashboardBuilder().build(boss:machine:needsMe:coding:…)` — fed real
/// `MailboxNeedsMeView` / `MailboxCodingSummary` Core values (the mailbox decode shape),
/// the EXACT builder `refreshBossDashboard()` calls. The `model` is built via the
/// `makeVM` dual-injection store seam (AN-001 hermetic) — it's `@ObservedObject` only for
/// the tap actions (`selectSession` / `setBossPaneCollapsed`), which render no captured
/// node, so the captured content is entirely `dashboard`-driven. The list visible/overflow
/// split is decided by the real `BossPaneListPresentation.make(count:visibleLimit:)` the
/// view calls.
///
/// **Determinism (P3).** Fixed item labels/details/runners + fixed nav-ref focuses (no
/// machine path / clock / UUID). The `.help(...)` tooltips are dropped by the host
/// (AN-004). Byte-identical twice + `!contains("/Users/")`.
///
/// **Enumerated state-set:**
///   - `bothEmpty`     — no needsMe + no coding → the outer guard fails → EMPTY tree
///       (the self-hide the view promises).
///   - `needsMeOnly`   — needsMe items, no coding → only the "Needs Me" column header +
///       rows; no "Coding" column.
///   - `codingOnly`    — coding items, no needsMe → only the "Coding" column.
///   - `bothWithOverflow` — >3 needsMe items (above `visibleLimit`) + coding items → both
///       columns; the "Needs Me" column shows the first 3 + a "View all 5" overflow `Text`.
@MainActor
final class BossNeedsMeCodingColumnsStateSetTests: XCTestCase {

    // MARK: - Hermetic model (AN-001 dual-injection)

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c2-needsme-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    // MARK: - Provenance fixture (the REAL BossDashboardBuilder)

    private func needsMeItem(_ label: String, focus: String) -> MailboxNeedsMeItem {
        MailboxNeedsMeItem(
            urgency: "blocking-obligation",
            label: label,
            detail: "decision ready",
            ref: MailboxNavigationRef(tab: "sessions", focus: focus),
            ageMs: 100)
    }

    private func codingItem(_ runner: String, status: String, taskRef: String?) -> MailboxCodingItem {
        MailboxCodingItem(
            id: "coding-\(runner)",
            runner: runner,
            status: status,
            workdir: "/tmp/u4-repo",
            lastActivityAt: nil,
            checkpoint: "green",
            taskRef: taskRef)
    }

    /// Build the dashboard through the REAL builder from real mailbox views.
    private func dashboard(
        needsMe: [MailboxNeedsMeItem] = [],
        coding: [MailboxCodingItem] = []
    ) -> BossDashboardSnapshot {
        BossDashboardBuilder().build(
            boss: BossAgentSelection(agentName: "boss"),
            machine: nil,
            needsMe: MailboxNeedsMeView(items: needsMe),
            coding: MailboxCodingSummary(
                totalCount: coding.count,
                activeCount: coding.count,
                blockedCount: 0,
                items: coding))
    }

    private func columns(needsMe: [MailboxNeedsMeItem] = [], coding: [MailboxCodingItem] = []) throws -> BossNeedsMeCodingColumns {
        BossNeedsMeCodingColumns(dashboard: dashboard(needsMe: needsMe, coding: coding), model: try makeVM())
    }

    // MARK: - Enumerated state-set

    func testColumns_bothEmpty_selfHides() throws {
        let view = try columns()
        XCTAssertTrue(view.dashboard.needsMeItems.isEmpty && view.dashboard.codingItems.isEmpty,
                      "provenance: the builder produced empty columns")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertFalse(tree.contains("Needs Me"), "self-hide: no column headers render:\n\(tree)")
        XCTAssertFalse(tree.contains("Coding"), "self-hide: no column headers render:\n\(tree)")
        try assertViewSnapshot(of: view, named: "BossNeedsMeCodingColumns.bothEmpty")
    }

    func testColumns_needsMeOnly() throws {
        let view = try columns(needsMe: [needsMeItem("Review the migration", focus: "sess-1")])
        XCTAssertEqual(view.dashboard.needsMeItems.count, 1)
        XCTAssertTrue(view.dashboard.codingItems.isEmpty)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("Needs Me"), "the Needs Me column header renders:\n\(tree)")
        XCTAssertFalse(tree.contains("text=\"Coding\""), "no Coding column:\n\(tree)")
        try assertViewSnapshot(of: view, named: "BossNeedsMeCodingColumns.needsMeOnly")
    }

    func testColumns_codingOnly() throws {
        let view = try columns(coding: [codingItem("codex", status: "running", taskRef: "task-9")])
        XCTAssertTrue(view.dashboard.needsMeItems.isEmpty)
        XCTAssertEqual(view.dashboard.codingItems.count, 1)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("Coding"), "the Coding column header renders:\n\(tree)")
        XCTAssertFalse(tree.contains("Needs Me"), "no Needs Me column:\n\(tree)")
        try assertViewSnapshot(of: view, named: "BossNeedsMeCodingColumns.codingOnly")
    }

    func testColumns_bothWithOverflow() throws {
        // 5 needsMe items (> visibleLimit 3) → the column shows 3 + a "View all 5" control.
        let needsMe = (1...5).map { needsMeItem("Item \($0)", focus: "sess-\($0)") }
        let view = try columns(needsMe: needsMe, coding: [codingItem("codex", status: "running", taskRef: "task-1")])
        let presentation = BossPaneListPresentation.make(count: 5, visibleLimit: 3)
        XCTAssertEqual(presentation.viewAllLabel, "View all 5", "provenance: the overflow control's label")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("View all 5"), "overflow: the View-all control renders:\n\(tree)")
        // Only the first 3 items render inline (4 and 5 are behind the overflow).
        XCTAssertTrue(tree.contains("Item 1"), tree)
        XCTAssertTrue(tree.contains("Item 3"), tree)
        XCTAssertFalse(tree.contains("Item 4"), "overflow: item 4 is not rendered inline:\n\(tree)")
        try assertViewSnapshot(of: view, named: "BossNeedsMeCodingColumns.bothWithOverflow")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The outer guard, each column gate, and the overflow gate flip the captured tree;
    /// the item data drives the rendered row `Text`s.
    func testColumns_negativeControl_gatesFlipTree() throws {
        let empty = try ViewSnapshotHost.snapshotText(of: try columns())
        let needsMe = try ViewSnapshotHost.snapshotText(of: try columns(needsMe: [needsMeItem("Review", focus: "s1")]))
        let overflow = try ViewSnapshotHost.snapshotText(of: try columns(
            needsMe: (1...5).map { needsMeItem("Item \($0)", focus: "s\($0)") }))

        XCTAssertNotEqual(empty, needsMe, "the outer guard must self-hide the empty case")
        XCTAssertFalse(empty.contains("Needs Me"), "empty: self-hidden:\n\(empty)")
        XCTAssertTrue(needsMe.contains("Review – decision ready"), "row: the item label+detail render:\n\(needsMe)")

        XCTAssertNotEqual(needsMe, overflow, "the overflow gate must add the View-all control")
        XCTAssertFalse(needsMe.contains("View all"), "single item: no overflow:\n\(needsMe)")
        XCTAssertTrue(overflow.contains("View all 5"), "overflow: the control renders:\n\(overflow)")
    }

    // MARK: - Determinism (P3)

    func testColumns_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, () throws -> BossNeedsMeCodingColumns)] = [
            ("bothEmpty", { try self.columns() }),
            ("needsMeOnly", { try self.columns(needsMe: [self.needsMeItem("Review", focus: "s1")]) }),
            ("codingOnly", { try self.columns(coding: [self.codingItem("codex", status: "running", taskRef: "t1")]) }),
            ("bothWithOverflow", { try self.columns(
                needsMe: (1...5).map { self.needsMeItem("Item \($0)", focus: "s\($0)") },
                coding: [self.codingItem("codex", status: "running", taskRef: "t1")]) })
        ]
        for (name, make) in cases {
            let a = try ViewSnapshotHost.snapshotText(of: try make())
            let b = try ViewSnapshotHost.snapshotText(of: try make())
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }
}
#endif
