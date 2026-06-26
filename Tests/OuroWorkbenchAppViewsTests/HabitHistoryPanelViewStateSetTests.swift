#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C2-4 — `HabitHistoryPanelView` (the dashboard's habit-history panel). LOGIC: it flips
/// on `if model.rows.isEmpty` (the status-message `Text`) vs `ForEach(model.rows.prefix(5))`
/// (a multi-line row per habit run), and within each row on `if let operationId` (the
/// operation-id `Text` appears only when present). Each branch flips CAPTURED `Text` nodes.
///
/// **Provenance (P2).** The `HabitHistoryPanelModel` is provenance-built through its REAL
/// initializer — `HabitHistoryPanelModel(summaries:isAvailable:issue:)` — the EXACT init
/// `BossDashboardBuilder.build(...)` calls to assemble `dashboard.habitHistory`. The
/// `summaries` are real `MailboxHabitSessionSummary` Core values (the mailbox decode
/// shape). The row fields (`habitName`/`outcome`/`endedAt`/`summary`/`operationId`/
/// `receiptLocator`) are derived by `HabitHistoryPanelRow.init(summary:)` — the same
/// production mapping. We do NOT hand-assemble the rows.
///
/// **Determinism (P3).** `endedAt` is a PRE-FORMATTED string in the model (the mailbox
/// `completedAt` ISO string, baked upstream — NOT a live `Date`), so a fixed string is
/// byte-stable with no clock seam. The `receiptLocator`/`operationId` use FIXED, relative
/// `arc/...` / `state/...` locators (the `BossDashboardTests` precedent) — no machine path.
/// The `.help(...)` tooltip is dropped by the host (AN-004). Byte-identical twice +
/// `!contains("/Users/")`.
///
/// **Enumerated state-set:**
///   - `empty`          — `rows.isEmpty`, available → the "No habit runs yet" status `Text`.
///   - `unavailable`    — `isAvailable == false` with an issue → the
///       "Habit history unavailable: …" status `Text` (the orange not-a-value arm).
///   - `oneWithOpId`    — a single summary WITH an `operationId` → the row's
///       habitName/outcome/endedAt/summary/operationId/receiptLocator `Text`s.
///   - `oneNoOpId`      — a single summary WITHOUT an `operationId` → the `if let
///       operationId` arm omits that `Text` (the in-row gate).
@MainActor
final class HabitHistoryPanelViewStateSetTests: XCTestCase {

    /// A real `MailboxHabitSessionSummary` (the mailbox decode shape) with FIXED,
    /// relative locators + a FIXED pre-formatted `completedAt` — no machine value.
    private func summary(
        runId: String,
        habit: String,
        operationId: String?,
        completedAt: String = "2026-06-11T10:01:00.000Z"
    ) -> MailboxHabitSessionSummary {
        MailboxHabitSessionSummary(
            runId: runId,
            habitName: habit,
            operationId: operationId,
            status: "surfaced",
            triggeredAt: "2026-06-11T10:00:00.000Z",
            completedAt: completedAt,
            summary: "Queued iMessage and recorded the route.",
            decisions: [],
            pending: MailboxHabitSummaryPending(count: 0, files: []),
            messagesSent: [],
            toolsUsed: [],
            producedRefs: [],
            errors: [],
            warnings: [],
            nextLikelyStep: nil,
            sources: MailboxHabitSummarySources(
                receipt: "arc/flight-recorder/habit-receipts/\(runId).json",
                session: "state/habit-sessions/\(runId)/session.json",
                pending: "state/habit-sessions/\(runId)/pending",
                runtimeState: "state/habits/\(habit).json"
            )
        )
    }

    /// Build the panel model through the REAL init (the same one the builder calls).
    private func model(
        summaries: [MailboxHabitSessionSummary] = [],
        isAvailable: Bool = true,
        issue: String? = nil
    ) -> HabitHistoryPanelModel {
        HabitHistoryPanelModel(summaries: summaries, isAvailable: isAvailable, issue: issue)
    }

    // MARK: - Enumerated state-set

    func testPanel_empty() throws {
        let model = model()
        XCTAssertTrue(model.rows.isEmpty, "provenance: no summaries → no rows")
        XCTAssertEqual(model.statusMessage, "No habit runs yet")
        try assertViewSnapshot(of: HabitHistoryPanelView(model: model), named: "HabitHistoryPanelView.empty")
    }

    func testPanel_unavailable() throws {
        let model = model(isAvailable: false, issue: "habit-history: timed out")
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.statusMessage, "Habit history unavailable: habit-history: timed out",
                       "provenance: the unavailable status message (orange arm)")
        try assertViewSnapshot(of: HabitHistoryPanelView(model: model), named: "HabitHistoryPanelView.unavailable")
    }

    func testPanel_oneWithOpId() throws {
        let model = model(summaries: [summary(runId: "run-a", habit: "heartbeat", operationId: "habit:heartbeat")])
        XCTAssertEqual(model.rows.count, 1, "provenance: one mapped row")
        XCTAssertEqual(model.rows[0].operationId, "habit:heartbeat")
        let tree = try ViewSnapshotHost.snapshotText(of: HabitHistoryPanelView(model: model))
        XCTAssertTrue(tree.contains("habit:heartbeat"), "the operationId Text renders:\n\(tree)")
        try assertViewSnapshot(of: HabitHistoryPanelView(model: model), named: "HabitHistoryPanelView.oneWithOpId")
    }

    func testPanel_oneNoOpId() throws {
        let model = model(summaries: [summary(runId: "run-b", habit: "digest", operationId: nil)])
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertNil(model.rows[0].operationId, "provenance: no operationId → the if-let arm omits it")
        let tree = try ViewSnapshotHost.snapshotText(of: HabitHistoryPanelView(model: model))
        XCTAssertFalse(tree.contains("habit:"), "no operationId: that Text must not render:\n\(tree)")
        try assertViewSnapshot(of: HabitHistoryPanelView(model: model), named: "HabitHistoryPanelView.oneNoOpId")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The `rows.isEmpty` gate and the per-row `if let operationId` gate each flip the
    /// captured tree, and the row data drives the rendered `Text`s.
    func testPanel_negativeControl_emptyGateAndOpIdGateFlipTree() throws {
        let empty = try ViewSnapshotHost.snapshotText(of: HabitHistoryPanelView(model: model()))
        let withOp = try ViewSnapshotHost.snapshotText(of: HabitHistoryPanelView(model: model(
            summaries: [summary(runId: "run-a", habit: "heartbeat", operationId: "habit:heartbeat")])))
        let noOp = try ViewSnapshotHost.snapshotText(of: HabitHistoryPanelView(model: model(
            summaries: [summary(runId: "run-b", habit: "heartbeat", operationId: nil)])))

        XCTAssertNotEqual(empty, withOp, "the rows.isEmpty gate must drive the tree")
        XCTAssertTrue(empty.contains("No habit runs yet"), "empty: the status message:\n\(empty)")
        XCTAssertTrue(withOp.contains(#"text="heartbeat""#), "row: the habit name renders:\n\(withOp)")

        XCTAssertNotEqual(withOp, noOp, "the if-let operationId gate must flip the tree")
        XCTAssertTrue(withOp.contains("habit:heartbeat"), withOp)
        XCTAssertFalse(noOp.contains("habit:heartbeat"), "noOp: the operationId Text must be absent:\n\(noOp)")
    }

    // MARK: - Determinism (P3)

    func testPanel_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, HabitHistoryPanelModel)] = [
            ("empty", model()),
            ("unavailable", model(isAvailable: false, issue: "habit-history: timed out")),
            ("oneWithOpId", model(summaries: [summary(runId: "run-a", habit: "heartbeat", operationId: "habit:heartbeat")])),
            ("oneNoOpId", model(summaries: [summary(runId: "run-b", habit: "digest", operationId: nil)]))
        ]
        for (name, m) in cases {
            let a = try ViewSnapshotHost.snapshotText(of: HabitHistoryPanelView(model: m))
            let b = try ViewSnapshotHost.snapshotText(of: HabitHistoryPanelView(model: m))
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }
}
#endif
