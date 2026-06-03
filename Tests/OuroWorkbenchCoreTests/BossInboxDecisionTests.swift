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

    // MARK: - Cross-channel double-send unification (P0)

    /// A boss reply often emits BOTH a `sendInput` action AND an `autoAdvance`
    /// decision for the same waiting prompt ("act and log"). The two channels
    /// (`applyBossActions` → sendInput, then `recordBossDecisions` → sendInput)
    /// share ONE per-(entry, prompt) guard via the decision log, so the
    /// keystroke is sent exactly once. This models that shared guard: the
    /// actions channel runs first and records the send; the decisions channel
    /// then keys on the *same* (entryId, live prompt) and is a no-op.
    func testActionAndDecisionForSameEntryAndPromptSendInputOnce() throws {
        // One reply, both blocks, same entry + same waiting prompt.
        let entryToken = "PROC-1"
        let entryId = UUID()
        let livePrompt = "Run tests? (y/N)"
        let reply = """
        I'll approve the test run and log it.

        ```ouro-workbench-actions
        [{"action":"sendInput","entry":"\(entryToken)","text":"y"}]
        ```

        ```ouro-workbench-decisions
        [{"entry":"\(entryToken)","kind":"autoAdvance","proposedInput":"y","reasoning":"pre-approved test run","prompt":"\(livePrompt)"}]
        ```
        """
        let actions = try BossWorkbenchActionParser().parse(reply)
        let decisions = try BossDecisionParser().parse(reply)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(decisions.count, 1)

        var state = WorkspaceState()
        var sendCount = 0

        // Channel 1 (actions): both channels key on the live transcript-tail
        // prompt, so they share a dedup key. Send + record under that guard.
        for action in actions where action.action == .sendInput {
            if state.isNewDecision(entryId: entryId, prompt: livePrompt, kind: .autoAdvance) {
                sendCount += 1 // sendInput(...)
                state.recordDecision(
                    BossInboxDecision(
                        source: "boss",
                        entryId: entryId,
                        prompt: livePrompt,
                        kind: .autoAdvance,
                        proposedInput: action.text,
                        reasoning: "actions channel",
                        status: .applied
                    )
                )
            }
        }

        // Channel 2 (decisions): same (entryId, prompt, autoAdvance) — the guard
        // already saw it, so this is a no-op (no second keystroke).
        for input in decisions where input.kind == .autoAdvance {
            guard state.isNewDecision(entryId: entryId, prompt: livePrompt, kind: .autoAdvance) else {
                continue
            }
            sendCount += 1 // sendInput(...) — must NOT happen
            state.recordDecision(
                BossInboxDecision(
                    source: "boss",
                    entryId: entryId,
                    prompt: livePrompt,
                    kind: .autoAdvance,
                    proposedInput: input.proposedInput,
                    reasoning: "decisions channel",
                    status: .applied
                )
            )
        }

        XCTAssertEqual(sendCount, 1, "the keystroke must be sent exactly once across both channels")
        XCTAssertEqual(state.decisionLog.count, 1, "only one decision is recorded for the shared (entry, prompt)")
        XCTAssertEqual(state.decisionLog.first?.reasoning, "actions channel", "the actions channel acted; decisions channel was the no-op")
    }

    /// The reverse case must keep working: a reply with an `autoAdvance`
    /// decision for one entry and a `sendInput` action for a DIFFERENT entry
    /// sends both — the guard is per-(entry, prompt), not a blanket lock.
    func testActionAndDecisionForDifferentEntriesBothSend() {
        let entryA = UUID()
        let entryB = UUID()
        let promptA = "Run tests? (y/N)"
        let promptB = "Apply the migration? (y/N)"
        var state = WorkspaceState()
        var sendCount = 0

        // Actions channel: send to entryA.
        if state.isNewDecision(entryId: entryA, prompt: promptA, kind: .autoAdvance) {
            sendCount += 1
            state.recordDecision(BossInboxDecision(source: "boss", entryId: entryA, prompt: promptA, kind: .autoAdvance, proposedInput: "y", reasoning: "actions", status: .applied))
        }
        // Decisions channel: autoAdvance for entryB — different entry, must send.
        if state.isNewDecision(entryId: entryB, prompt: promptB, kind: .autoAdvance) {
            sendCount += 1
            state.recordDecision(BossInboxDecision(source: "boss", entryId: entryB, prompt: promptB, kind: .autoAdvance, proposedInput: "y", reasoning: "decisions", status: .applied))
        }

        XCTAssertEqual(sendCount, 2, "independent entries each get their keystroke")
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

    func testParsesMarkerDecisionsWithTrailingProse() throws {
        // The marker fallback (no ```ouro-workbench-decisions fence) must capture
        // only the balanced JSON array — trailing prose after it used to make
        // the payload invalid JSON and silently drop the whole batch.
        let reply = """
        OURO_WORKBENCH_DECISIONS: [{"entry":"PROC-1","kind":"autoAdvance","proposedInput":"y","preferenceCited":"Ari: approve test runs","confidence":0.9,"reasoning":"pre-approved test run","prompt":"Run tests? (y/N)"}]
        Some trailing explanation about why I did that.
        """

        let decisions = try BossDecisionParser().parse(reply)

        XCTAssertEqual(decisions.count, 1, "trailing prose after the JSON is ignored, not fatal")
        XCTAssertEqual(decisions[0].entry, "PROC-1")
        XCTAssertEqual(decisions[0].kind, .autoAdvance)
        XCTAssertEqual(decisions[0].proposedInput, "y")
        XCTAssertEqual(decisions[0].confidence, 0.9)
    }

    func testParsesMarkerDecisionsWithLeadingAndTrailingProse() throws {
        // Prose on both sides of the marker line, multiple decisions, and a
        // string value containing a `]` that must not be mistaken for the
        // array's close.
        let reply = """
        Here's my read on the waiting sessions.
        OURO_WORKBENCH_DECISIONS: [
          {"entry":"PROC-1","kind":"autoAdvance","proposedInput":"1","reasoning":"pick option [1]","prompt":"Choose? (1/2)"},
          {"entry":"PROC-2","kind":"escalate","reasoning":"no preference covers this"}
        ]
        I'll check back in a bit.
        """

        let decisions = try BossDecisionParser().parse(reply)

        XCTAssertEqual(decisions.count, 2)
        XCTAssertEqual(decisions[0].kind, .autoAdvance)
        XCTAssertEqual(decisions[0].proposedInput, "1")
        XCTAssertEqual(decisions[0].reasoning, "pick option [1]")
        XCTAssertEqual(decisions[1].kind, .escalate)
    }
}
