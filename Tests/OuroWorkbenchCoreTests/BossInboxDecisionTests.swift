import XCTest
@testable import OuroWorkbenchCore

final class BossInboxDecisionTests: XCTestCase {
    private func decision(_ kind: BossDecisionKind, reasoning: String = "because") -> BossInboxDecision {
        BossInboxDecision(source: "boss:slugger", prompt: "Proceed? (y/N)", kind: kind, reasoning: reasoning)
    }

    func testRecordDecisionInsertsNewestFirst() {
        var state = WorkspaceState()
        state.recordDecision(decision(.escalate, reasoning: "first"))
        state.recordDecision(decision(.autoAdvance, reasoning: "second"))
        XCTAssertEqual(state.decisionLog.count, 2)
        XCTAssertEqual(state.decisionLog.first?.reasoning, "second", "newest is first")
        XCTAssertEqual(state.decisionLog.last?.reasoning, "first")
    }

    func testRecordDecisionTrimsToCap() {
        var state = WorkspaceState()
        for i in 0..<(WorkspaceState.decisionLogCap + 25) {
            state.recordDecision(decision(.hold, reasoning: "d\(i)"))
        }
        XCTAssertEqual(state.decisionLog.count, WorkspaceState.decisionLogCap)
        // The most recent survives; the oldest are trimmed.
        XCTAssertEqual(state.decisionLog.first?.reasoning, "d\(WorkspaceState.decisionLogCap + 24)")
    }

    func testUnknownKindAndStatusDecodeToSafeDefaults() throws {
        let kind = try JSONDecoder().decode(BossDecisionKind.self, from: Data("\"teleport\"".utf8))
        XCTAssertEqual(kind, .escalate, "unknown decision kind is the non-acting choice")
        let status = try JSONDecoder().decode(BossDecisionStatus.self, from: Data("\"vibes\"".utf8))
        XCTAssertEqual(status, .recorded)
    }

    func testDecisionRoundTripsWithFullAuditFields() throws {
        let original = BossInboxDecision(
            source: "boss:slugger",
            entryId: UUID(),
            sessionName: "Codex",
            friendName: "Ari",
            friendId: "ari",
            prompt: "Run tests? (y/N)",
            kind: .autoAdvance,
            proposedInput: "y",
            preferenceCited: "Ari note: test runs are fine",
            confidence: 0.92,
            reasoning: "matches an explicit preference",
            status: .recorded
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BossInboxDecision.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testWorkspaceStateWithoutDecisionLogDecodesToEmpty() throws {
        // A pre-decision-log persisted state (no `decisionLog` key) loads with [].
        // Default JSONDecoder date strategy is numeric (seconds since reference date).
        let json = """
        {"schemaVersion":1,"boss":{"agentName":"slugger","scope":"machine"},"projects":[],"processEntries":[],"processRuns":[],"actionLog":[],"updatedAt":0}
        """
        let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(json.utf8))
        XCTAssertEqual(state.decisionLog, [])
    }

    func testDecisionLogRoundTripsThroughWorkspaceState() throws {
        var state = WorkspaceState()
        state.recordDecision(decision(.autoAdvance, reasoning: "keep going"))
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: data)
        XCTAssertEqual(decoded.decisionLog.count, 1)
        XCTAssertEqual(decoded.decisionLog.first?.reasoning, "keep going")
    }

    // MARK: - Dedup

    func testRecordDecisionIfNewSkipsDuplicateForSameSessionAndPrompt() {
        let entryId = UUID()
        func d(_ kind: BossDecisionKind) -> BossInboxDecision {
            BossInboxDecision(source: "boss", entryId: entryId, prompt: "Run tests? (y/N)", kind: kind, reasoning: "r")
        }
        var state = WorkspaceState()
        XCTAssertTrue(state.recordDecisionIfNew(d(.autoAdvance)))
        XCTAssertFalse(state.recordDecisionIfNew(d(.autoAdvance)), "same session+prompt+kind is a no-op")
        XCTAssertEqual(state.decisionLog.count, 1)
        // A different kind for the same prompt is a real change — record it.
        XCTAssertTrue(state.recordDecisionIfNew(d(.escalate)))
        XCTAssertEqual(state.decisionLog.count, 2)
    }

    // MARK: - Parser

    func testParsesFencedDecisionsBlock() throws {
        let reply = """
        Here's my read.

        ```ouro-workbench-decisions
        [{"entry":"PROC-1","kind":"autoAdvance","proposedInput":"1","preferenceCited":"Ari: approve test runs","confidence":0.9,"reasoning":"test-run approval","prompt":"Run tests? (y/N)"},
         {"entry":"PROC-2","kind":"escalate","reasoning":"no preference covers this"}]
        ```
        """
        let decisions = try BossDecisionParser().parse(reply)
        XCTAssertEqual(decisions.count, 2)
        XCTAssertEqual(decisions[0].kind, .autoAdvance)
        XCTAssertEqual(decisions[0].proposedInput, "1")
        XCTAssertEqual(decisions[0].confidence, 0.9)
        XCTAssertEqual(decisions[1].kind, .escalate)
        XCTAssertNil(decisions[1].proposedInput)
    }

    func testParserDropsOneMalformedDecisionKeepsRest() throws {
        let reply = """
        ```ouro-workbench-decisions
        [{"kind":"hold","reasoning":"ok"}, 42, {"entry":"P","kind":"escalate","reasoning":"x"}]
        ```
        """
        let decisions = try BossDecisionParser().parse(reply)
        XCTAssertEqual(decisions.count, 2, "the bare number is skipped; valid decisions survive")
    }

    func testParserReturnsEmptyWhenNoBlock() throws {
        XCTAssertEqual(try BossDecisionParser().parse("just prose, no decisions").count, 0)
    }
}
