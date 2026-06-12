import XCTest
@testable import OuroWorkbenchCore

final class HabitHistoryPanelTests: XCTestCase {
    func testFormatsHabitSummaryRowsForCompactHistoryPanel() {
        let summary = makeHabitSummary(
            runId: "run-1",
            habitName: "heartbeat",
            operationId: "habit:heartbeat",
            status: "surfaced",
            completedAt: "2026-06-11T10:01:00.000Z",
            summary: "Queued an iMessage and recorded the route.",
            receipt: "arc/flight-recorder/habit-receipts/run-1.json"
        )

        let model = HabitHistoryPanelModel(summaries: [summary])

        XCTAssertEqual(model.title, "Habit History")
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows.first?.habitName, "heartbeat")
        XCTAssertEqual(model.rows.first?.outcome, "surfaced")
        XCTAssertEqual(model.rows.first?.endedAt, "2026-06-11T10:01:00.000Z")
        XCTAssertEqual(model.rows.first?.summary, "Queued an iMessage and recorded the route.")
        XCTAssertEqual(model.rows.first?.operationId, "habit:heartbeat")
        XCTAssertEqual(model.rows.first?.receiptLocator, "arc/flight-recorder/habit-receipts/run-1.json")
        XCTAssertEqual(model.rows.first?.sourceLocator, "state/habit-sessions/run-1/session.json")
    }

    func testDashboardBuilderCarriesHabitHistory() {
        let history = MailboxHabitSessionSummaryView(
            totalCount: 1,
            limit: 5,
            items: [
                makeHabitSummary(
                    runId: "run-history",
                    habitName: "stateful-check",
                    operationId: "habit:stateful-check",
                    status: "blocked",
                    completedAt: "2026-06-11T10:05:00.000Z",
                    summary: "Asked Ari for a missing credential.",
                    receipt: "arc/flight-recorder/habit-receipts/run-history.json"
                )
            ]
        )

        let snapshot = BossDashboardBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            machine: nil,
            needsMe: nil,
            coding: nil,
            habitHistory: history
        )

        XCTAssertEqual(snapshot.habitHistory.rows.map(\.habitName), ["stateful-check"])
        XCTAssertEqual(snapshot.habitHistory.rows.first?.operationId, "habit:stateful-check")
        XCTAssertEqual(snapshot.habitHistory.rows.first?.summary, "Asked Ari for a missing credential.")
    }

    func testHandlesEmptyAndLongSparseHistoryRows() {
        let empty = HabitHistoryPanelModel()
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertTrue(empty.isAvailable)
        XCTAssertEqual(empty.statusMessage, "No habit runs yet")

        let longSummary = String(repeating: "handoff ", count: 80)
        let model = HabitHistoryPanelModel(summaries: [
            makeHabitSummary(
                runId: "run-long",
                habitName: "long-check",
                operationId: nil,
                status: "no_change",
                completedAt: "2026-06-11T10:10:00.000Z",
                summary: longSummary,
                receipt: "arc/flight-recorder/habit-receipts/run-long.json"
            )
        ])

        XCTAssertNil(model.rows.first?.operationId)
        XCTAssertEqual(model.rows.first?.summary, longSummary)
        XCTAssertEqual(model.rows.first?.sourceLocator, "state/habit-sessions/run-long/session.json")
        XCTAssertNil(model.statusMessage)
    }

    func testUnavailableHistoryKeepsPanelVisibleWithErrorState() {
        let model = HabitHistoryPanelModel(
            summaries: [],
            isAvailable: false,
            issue: "habit-history: The Ouro mailbox did not answer before the Workbench timeout."
        )

        XCTAssertFalse(model.isAvailable)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.statusMessage, "Habit history unavailable: habit-history: The Ouro mailbox did not answer before the Workbench timeout.")
    }

    private func makeHabitSummary(
        runId: String,
        habitName: String,
        operationId: String?,
        status: String,
        completedAt: String,
        summary: String,
        receipt: String
    ) -> MailboxHabitSessionSummary {
        MailboxHabitSessionSummary(
            runId: runId,
            habitName: habitName,
            operationId: operationId,
            status: status,
            triggeredAt: "2026-06-11T10:00:00.000Z",
            completedAt: completedAt,
            summary: summary,
            decisions: [],
            pending: MailboxHabitSummaryPending(count: 0, files: []),
            messagesSent: [],
            toolsUsed: [],
            producedRefs: [],
            errors: [],
            warnings: [],
            nextLikelyStep: nil,
            sources: MailboxHabitSummarySources(
                receipt: receipt,
                session: "state/habit-sessions/\(runId)/session.json",
                pending: "state/habit-sessions/\(runId)/pending",
                runtimeState: "state/habits/\(habitName).json"
            )
        )
    }
}
