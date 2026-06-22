import XCTest
@testable import OuroWorkbenchCore

/// F12a Gap 3a — the durable boss-prose history. `bossCheckInAnswer` is a transient
/// @Published string the next tick overwrites, so the operator's record of what the
/// boss SAID is lost. `proseLog` persists it (additive Codable, no schemaVersion
/// bump), newest-first, capped at 50, text capped at 4000.
final class WorkspaceStateProseLogTests: XCTestCase {
    func testRecordProseAppendsNewestFirst() {
        var state = WorkspaceState()
        state.recordProse(BossProseEntry(source: "boss:slugger", text: "first"))
        state.recordProse(BossProseEntry(source: "boss:slugger", text: "second"))
        XCTAssertEqual(state.proseLog.count, 2)
        XCTAssertEqual(state.proseLog.first?.text, "second", "newest-first")
        XCTAssertEqual(state.proseLog.last?.text, "first")
    }

    func testRecordProseTrimsToCap() {
        var state = WorkspaceState()
        for i in 0..<(WorkspaceState.proseLogCap + 10) {
            state.recordProse(BossProseEntry(source: "boss", text: "entry-\(i)"))
        }
        XCTAssertEqual(state.proseLog.count, WorkspaceState.proseLogCap)
        // The newest entries survive; the oldest are trimmed.
        XCTAssertEqual(state.proseLog.first?.text, "entry-\(WorkspaceState.proseLogCap + 9)")
        XCTAssertFalse(state.proseLog.contains { $0.text == "entry-0" })
    }

    func testProseEntryTextIsCappedAtConstruction() {
        let huge = String(repeating: "x", count: 10_000)
        let entry = BossProseEntry(source: "boss", text: huge)
        XCTAssertEqual(entry.text.count, BossProseEntry.textCap)
    }

    func testProseLogDecodesAbsentAsEmptyForPreF12aState() throws {
        // A pre-F12a state file has no `proseLog` key; it must decode as [] so old
        // state loads unchanged (additive, no schemaVersion bump).
        let json = """
        {"schemaVersion":1,"boss":{"agentName":"","scope":"machine"},"bossWatchEnabled":true,"bossPaneCollapsed":false,"projects":[],"processEntries":[],"processRuns":[],"actionLog":[],"decisionLog":[],"updatedAt":0}
        """
        let decoder = JSONDecoder()
        let state = try decoder.decode(WorkspaceState.self, from: Data(json.utf8))
        XCTAssertEqual(state.proseLog, [])
    }

    func testProseLogRoundTripsThroughCodable() throws {
        var state = WorkspaceState()
        state.recordProse(BossProseEntry(source: "boss:slugger", text: "everything is quiet"))
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(state)
        let decoded = try decoder.decode(WorkspaceState.self, from: data)
        XCTAssertEqual(decoded.proseLog.count, 1)
        XCTAssertEqual(decoded.proseLog.first?.text, "everything is quiet")
        XCTAssertEqual(decoded.proseLog.first?.source, "boss:slugger")
    }
}
