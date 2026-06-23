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
        // RESOLVED decisions are audit-only (out of the open queue), so the cap is
        // free to shed the oldest — the bounded behavior. (An OPEN escalation is
        // never evicted; that invariant is covered by the FIX-1 cap tests below.)
        var state = WorkspaceState()
        for i in 0..<(WorkspaceState.decisionLogCap + 25) {
            var d = decision(.hold, reasoning: "d\(i)")
            d.triage = .resolved(at: Date())
            state.recordDecision(d)
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

    func testDecisionInputInitializerStoresAllFields() {
        let input = BossInboxDecisionInput(
            entry: "Codex",
            kind: .autoAdvance,
            proposedInput: "1",
            preferenceCited: "tests are okay",
            confidence: 0.9,
            reasoning: "matches preference",
            prompt: "Run tests?"
        )

        XCTAssertEqual(input.entry, "Codex")
        XCTAssertEqual(input.kind, .autoAdvance)
        XCTAssertEqual(input.proposedInput, "1")
        XCTAssertEqual(input.preferenceCited, "tests are okay")
        XCTAssertEqual(input.confidence, 0.9)
        XCTAssertEqual(input.reasoning, "matches preference")
        XCTAssertEqual(input.prompt, "Run tests?")
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

    // MARK: - FIX 2: dedup scans a window, not just the latest row

    func testInterleavedPromptsDoNotRefireAnEarlierDecision() {
        // A→B→A on the SAME entry. Once A is decided and then B becomes the entry's
        // newest decision, A reappearing must NOT be treated as new — otherwise the
        // boss re-sends input to a prompt it already advanced. The old `.first`-only
        // compare matched B (the latest row), saw A≠B, and wrongly re-fired A.
        let entryId = UUID()
        func d(_ prompt: String, _ kind: BossDecisionKind = .autoAdvance) -> BossInboxDecision {
            BossInboxDecision(source: "boss", entryId: entryId, prompt: prompt, kind: kind, reasoning: "r")
        }
        var state = WorkspaceState()
        XCTAssertTrue(state.recordDecisionIfNew(d("Prompt A? (y/N)")), "A is new")
        XCTAssertTrue(state.recordDecisionIfNew(d("Prompt B? (y/N)")), "B is a different prompt — new")
        XCTAssertFalse(
            state.isNewDecision(entryId: entryId, prompt: "Prompt A? (y/N)", kind: .autoAdvance),
            "A is in the recent window for this entry — NOT new, so the boss won't re-send"
        )
        XCTAssertFalse(state.recordDecisionIfNew(d("Prompt A? (y/N)")), "re-recording A is a no-op")
        XCTAssertEqual(state.decisionLog.count, 2, "only A and B exist — A did not duplicate")
    }

    func testDedupDistinguishesPromptAndKindWithinWindow() {
        // Inverse-bug guard: the window must NOT over-dedupe genuinely-distinct
        // decisions. Same entry, but a different prompt OR a different kind is new.
        let entryId = UUID()
        func d(_ prompt: String, _ kind: BossDecisionKind) -> BossInboxDecision {
            BossInboxDecision(source: "boss", entryId: entryId, prompt: prompt, kind: kind, reasoning: "r")
        }
        var state = WorkspaceState()
        XCTAssertTrue(state.recordDecisionIfNew(d("Prompt A? (y/N)", .autoAdvance)))
        XCTAssertTrue(state.isNewDecision(entryId: entryId, prompt: "Different? (y/N)", kind: .autoAdvance), "different prompt is new")
        XCTAssertTrue(state.isNewDecision(entryId: entryId, prompt: "Prompt A? (y/N)", kind: .escalate), "same prompt, different kind is new")
        XCTAssertTrue(state.isNewDecision(entryId: UUID(), prompt: "Prompt A? (y/N)", kind: .autoAdvance), "different entry is new")
    }

    func testIsNewDecisionDedupesNilEntryByStablePseudoKey() {
        // A nil-entry decision (the boss referenced a session that couldn't be
        // uniquely resolved) still dedupes — by the stable (sessionName, prompt,
        // kind) pseudo-key — so a repeated tick isn't re-recorded. Different prompt
        // OR target stays new (inverse-bug guard).
        var state = WorkspaceState()
        let d = BossInboxDecision(source: "boss", entryId: nil, sessionName: "ambiguous", prompt: "Proceed? (y/N)", kind: .escalate, reasoning: "r")
        state.recordDecision(d)
        XCTAssertFalse(
            state.isNewDecision(entryId: nil, prompt: "Proceed? (y/N)", kind: .escalate, sessionName: "ambiguous"),
            "an identical nil-entry decision is not new"
        )
        XCTAssertTrue(
            state.isNewDecision(entryId: nil, prompt: "Different? (y/N)", kind: .escalate, sessionName: "ambiguous"),
            "a different prompt for the same nil target is new"
        )
        XCTAssertTrue(
            state.isNewDecision(entryId: nil, prompt: "Proceed? (y/N)", kind: .escalate, sessionName: "other"),
            "the same prompt for a different nil target is new"
        )
        // The real App path passes sessionName == nil for an unresolved entry; the
        // pseudo-key still collapses identical repeats by (prompt, kind).
        var s2 = WorkspaceState()
        s2.recordDecision(BossInboxDecision(source: "boss", entryId: nil, sessionName: nil, prompt: "Unresolved? (y/N)", kind: .escalate, reasoning: "r"))
        XCTAssertFalse(
            s2.isNewDecision(entryId: nil, prompt: "Unresolved? (y/N)", kind: .escalate, sessionName: nil),
            "an identical nil-entry, nil-name decision is not new"
        )
    }

    func testDedupWindowIsBoundedSoAVeryOldMatchFallsOutOfScope() {
        // The window is bounded (dedupScanWindow). A matching decision pushed far
        // enough back by newer SAME-entry rows is outside the scan and reads as new
        // again — that's the intended bound (re-surfacing a long-stale prompt is
        // acceptable; flooding from a 1-row compare was not).
        let entryId = UUID()
        var state = WorkspaceState()
        let ancient = BossInboxDecision(source: "boss", entryId: entryId, prompt: "Ancient? (y/N)", kind: .autoAdvance, reasoning: "r")
        state.recordDecision(ancient)
        // Push `ancient` past the window with newer same-entry rows.
        for i in 0..<WorkspaceState.dedupScanWindow {
            state.recordDecision(BossInboxDecision(source: "boss", entryId: entryId, prompt: "filler-\(i)? (y/N)", kind: .autoAdvance, reasoning: "r"))
        }
        XCTAssertTrue(
            state.isNewDecision(entryId: entryId, prompt: "Ancient? (y/N)", kind: .autoAdvance),
            "a match beyond the bounded window is treated as new again"
        )
        // …but a match INSIDE the window is still caught.
        XCTAssertFalse(
            state.isNewDecision(entryId: entryId, prompt: "filler-0? (y/N)", kind: .autoAdvance),
            "the most recent filler is within the window — not new"
        )
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

    func testParserIgnoresUnclosedFencedBlock() throws {
        let reply = """
        ```ouro-workbench-decisions
        [{"entry":"PROC-1","kind":"autoAdvance","reasoning":"ok"}]
        """

        XCTAssertEqual(try BossDecisionParser().parse(reply).count, 0)
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

    // MARK: - Human triage transitions

    /// A fresh escalate has nil triage → open. Acknowledge / snooze / resolve
    /// each set the right state, and a later transition overwrites the earlier.
    func testTriageTransitionsSetState() {
        var state = WorkspaceState()
        let d = BossInboxDecision(source: "boss", entryId: UUID(), prompt: "Run tests? (y/N)", kind: .escalate, reasoning: "no pref")
        state.recordDecision(d)
        XCTAssertNil(state.decisionLog[0].triage, "a fresh decision is open (nil triage)")

        let t0 = Date()
        state.acknowledge(decisionID: d.id, at: t0)
        XCTAssertEqual(state.decisionLog[0].triage, .acknowledged(at: t0))

        let until = t0.addingTimeInterval(3600)
        state.snooze(decisionID: d.id, until: until)
        XCTAssertEqual(state.decisionLog[0].triage, .snoozed(until: until), "snooze overwrites acknowledged")

        let t1 = t0.addingTimeInterval(10)
        state.resolve(decisionID: d.id, at: t1)
        XCTAssertEqual(state.decisionLog[0].triage, .resolved(at: t1), "resolve overwrites snooze")
    }

    func testTriageDecodeDefaultsMissingDatesToNowEquivalentStates() throws {
        let snoozed = try JSONDecoder().decode(DecisionTriage.self, from: Data(#"{"state":"snoozed"}"#.utf8))
        if case let .snoozed(until) = snoozed {
            XCTAssertLessThan(abs(until.timeIntervalSinceNow), 5)
        } else {
            XCTFail("Expected missing snooze date to decode as snoozed")
        }
    }

    func testTriageMutationForUnknownIDIsNoOp() {
        var state = WorkspaceState()
        state.recordDecision(BossInboxDecision(source: "boss", entryId: UUID(), prompt: "p", kind: .escalate, reasoning: "r"))
        state.acknowledge(decisionID: UUID()) // id not in the log
        XCTAssertNil(state.decisionLog[0].triage, "an unknown id leaves the log untouched")
    }

    func testIsOpenForTriageHelper() {
        let now = Date()
        let open = BossInboxDecision(source: "b", prompt: "p", kind: .escalate, reasoning: "r")
        XCTAssertTrue(open.isOpenForTriage(at: now), "nil triage is open")
        let ack = BossInboxDecision(source: "b", prompt: "p", kind: .escalate, reasoning: "r", triage: .acknowledged(at: now))
        XCTAssertFalse(ack.isOpenForTriage(at: now))
        let snoozedActive = BossInboxDecision(source: "b", prompt: "p", kind: .escalate, reasoning: "r", triage: .snoozed(until: now.addingTimeInterval(60)))
        XCTAssertFalse(snoozedActive.isOpenForTriage(at: now), "an active snooze is hidden")
        let snoozedElapsed = BossInboxDecision(source: "b", prompt: "p", kind: .escalate, reasoning: "r", triage: .snoozed(until: now.addingTimeInterval(-60)))
        XCTAssertTrue(snoozedElapsed.isOpenForTriage(at: now), "an elapsed snooze is open again")
    }

    // MARK: - Severity

    func testSeverityFromKindAndPrompt() {
        let escalate = BossInboxDecision(source: "b", prompt: "Choose an option (1/2)", kind: .escalate, reasoning: "r")
        XCTAssertEqual(DecisionSeverity.of(escalate), .elevated, "a plain escalate is elevated")

        let hold = BossInboxDecision(source: "b", prompt: "Working…", kind: .hold, reasoning: "r")
        XCTAssertEqual(DecisionSeverity.of(hold), .low)

        let blockedAuto = BossInboxDecision(source: "b", prompt: "Continue? (y/N)", kind: .autoAdvance, reasoning: "r")
        XCTAssertEqual(DecisionSeverity.of(blockedAuto), .normal)

        // A destructive prompt is critical regardless of kind (PromptSafetyClassifier floor).
        let destructive = BossInboxDecision(source: "b", prompt: "rm -rf the build dir? (y/N)", kind: .escalate, reasoning: "r")
        XCTAssertEqual(DecisionSeverity.of(destructive), .critical)
        let secret = BossInboxDecision(source: "b", prompt: "Enter your password:", kind: .hold, reasoning: "r")
        XCTAssertEqual(DecisionSeverity.of(secret), .critical, "a secret prompt outranks even a hold's low tier")
    }

    func testSeverityIsAtMostFourTiers() {
        XCTAssertLessThanOrEqual(DecisionSeverity.allCases.count, 4, "anti-alarm-fatigue: keep severity tiers ≤4")
    }

    func testSeverityLabelsAndGroupIDAreStable() {
        XCTAssertEqual(DecisionSeverity.low.label, "Low")
        XCTAssertEqual(DecisionSeverity.normal.label, "Normal")
        XCTAssertEqual(DecisionSeverity.elevated.label, "Needs you")
        XCTAssertEqual(DecisionSeverity.critical.label, "Critical")
        XCTAssertEqual(InboxSeverityGroup(severity: .critical, decisions: []).id, DecisionSeverity.critical.rawValue)
    }

    func testUntilEndOfDayFallsBackWhenCalendarCannotResolveNextDay() {
        let interval = WorkbenchTriageInterval.untilEndOfDay(now: Date(timeIntervalSince1970: 0)) { _, _, _, _ in nil }

        XCTAssertEqual(interval, 86_400)
    }

    // MARK: - openInbox filtering & ordering

    private func escalate(entryId: UUID = UUID(), prompt: String, at: Date) -> BossInboxDecision {
        BossInboxDecision(occurredAt: at, source: "boss", entryId: entryId, sessionName: "s", prompt: prompt, kind: .escalate, reasoning: "r")
    }

    func testOpenInboxExcludesResolvedAndCurrentlySnoozed() {
        let now = Date()
        var state = WorkspaceState()
        let openD = escalate(prompt: "Choose? (1/2)", at: now)
        let resolvedD = escalate(prompt: "Already handled? (y/N)", at: now)
        let snoozedD = escalate(prompt: "Later? (y/N)", at: now)
        // Insert oldest-first via recordDecision (which prepends), so all three land.
        state.recordDecision(openD)
        state.recordDecision(resolvedD)
        state.recordDecision(snoozedD)
        state.resolve(decisionID: resolvedD.id, at: now)
        state.snooze(decisionID: snoozedD.id, until: now.addingTimeInterval(3600))

        let inbox = state.openInbox(now: now)
        XCTAssertEqual(inbox.map(\.id), [openD.id], "resolved + actively-snoozed are filtered out")
    }

    func testOpenInboxResurfacesExpiredSnooze() {
        let now = Date()
        var state = WorkspaceState()
        let d = escalate(prompt: "Resurface me? (y/N)", at: now)
        state.recordDecision(d)
        state.snooze(decisionID: d.id, until: now.addingTimeInterval(3600))

        XCTAssertTrue(state.openInbox(now: now).isEmpty, "hidden while the snooze is active")
        let later = now.addingTimeInterval(3601)
        XCTAssertEqual(state.openInbox(now: later).map(\.id), [d.id], "an expired snooze resurfaces in the queue")
    }

    func testOpenInboxOrdersBySeverityThenRecency() {
        let now = Date()
        var state = WorkspaceState()
        // Recorded oldest→newest. Severity should dominate recency.
        let oldDestructive = escalate(prompt: "rm -rf node_modules? (y/N)", at: now.addingTimeInterval(-100)) // critical, oldest
        let newPlain = escalate(prompt: "Choose? (1/2)", at: now)                                            // elevated, newest
        let midPlain = escalate(prompt: "Proceed? (y/N)", at: now.addingTimeInterval(-50))                   // elevated, middle
        state.recordDecision(oldDestructive)
        state.recordDecision(midPlain)
        state.recordDecision(newPlain)

        let inbox = state.openInbox(now: now)
        XCTAssertEqual(
            inbox.map(\.id),
            [oldDestructive.id, newPlain.id, midPlain.id],
            "critical first despite being oldest; within the elevated tier, newer before older"
        )
    }

    func testOpenInboxPreservesLogOrderWhenSeverityAndDateTie() {
        let now = Date()
        var state = WorkspaceState()
        let firstInLog = BossInboxDecision(occurredAt: now, source: "b", entryId: nil, prompt: "A?", kind: .escalate, reasoning: "newer")
        let secondInLog = BossInboxDecision(occurredAt: now, source: "b", entryId: nil, prompt: "B?", kind: .escalate, reasoning: "older")
        state.decisionLog = [firstInLog, secondInLog]

        XCTAssertEqual(state.openInbox(now: now).map(\.id), [firstInLog.id, secondInLog.id])
    }

    func testOpenInboxIncludesHoldAndBlockedAutoAdvanceButNotAppliedAutoAdvance() {
        let now = Date()
        var state = WorkspaceState()
        let held = BossInboxDecision(occurredAt: now, source: "b", entryId: UUID(), prompt: "Parked", kind: .hold, reasoning: "r")
        let blockedAuto = BossInboxDecision(occurredAt: now, source: "b", entryId: UUID(), prompt: "Continue? (y/N)", kind: .autoAdvance, reasoning: "r", status: .recorded)
        let appliedAuto = BossInboxDecision(occurredAt: now, source: "b", entryId: UUID(), prompt: "Run tests? (y/N)", kind: .autoAdvance, reasoning: "r", status: .applied)
        state.recordDecision(held)
        state.recordDecision(blockedAuto)
        state.recordDecision(appliedAuto)

        let ids = Set(state.openInbox(now: now).map(\.id))
        XCTAssertTrue(ids.contains(held.id), "a held decision needs the human")
        XCTAssertTrue(ids.contains(blockedAuto.id), "a blocked/recorded auto-advance fell back to the human")
        XCTAssertFalse(ids.contains(appliedAuto.id), "an applied auto-advance was handled — audit-only, not in the inbox")
    }

    func testOpenInboxDeduplicatesPerSessionKeepingNewest() {
        let now = Date()
        let entry = UUID()
        var state = WorkspaceState()
        let older = escalate(entryId: entry, prompt: "Old prompt? (y/N)", at: now.addingTimeInterval(-100))
        let newer = escalate(entryId: entry, prompt: "New prompt? (y/N)", at: now)
        state.recordDecision(older)
        state.recordDecision(newer)

        let inbox = state.openInbox(now: now)
        XCTAssertEqual(inbox.map(\.id), [newer.id], "one open row per session — the newest wins")
    }

    func testOpenInboxKeepsEntrylessDecisionsSeparately() {
        let now = Date()
        var state = WorkspaceState()
        let a = BossInboxDecision(occurredAt: now, source: "b", entryId: nil, prompt: "A? (y/N)", kind: .escalate, reasoning: "r")
        let b = BossInboxDecision(occurredAt: now.addingTimeInterval(-1), source: "b", entryId: nil, prompt: "B? (y/N)", kind: .escalate, reasoning: "r")
        state.recordDecision(b)
        state.recordDecision(a)
        XCTAssertEqual(Set(state.openInbox(now: now).map(\.id)), [a.id, b.id], "entry-less decisions aren't collapsed together")
    }

    func testOpenInboxGroupsAndCount() {
        let now = Date()
        var state = WorkspaceState()
        let crit = escalate(prompt: "git push --force? (y/N)", at: now)
        let plain = escalate(prompt: "Choose? (1/2)", at: now)
        state.recordDecision(crit)
        state.recordDecision(plain)

        XCTAssertEqual(state.openInboxCount(now: now), 2)
        let groups = state.openInboxGroups(now: now)
        XCTAssertEqual(groups.map(\.severity), [.critical, .elevated], "groups are most-severe first, empty tiers omitted")
        XCTAssertEqual(groups.first?.decisions.map(\.id), [crit.id])
        XCTAssertEqual(groups.last?.decisions.map(\.id), [plain.id])
    }

    // MARK: - Lenient decode of triage (no schemaVersion bump)

    func testDecisionWithoutTriageDecodesToOpen() throws {
        // A pre-triage persisted decision (no `triage` key) loads with nil triage
        // → open. Mirrors how `friend` / `detailLayout` were added additively.
        let json = """
        {"id":"\(UUID().uuidString)","occurredAt":0,"source":"boss","prompt":"Run tests? (y/N)","kind":"escalate","reasoning":"r","status":"recorded"}
        """
        let decoded = try JSONDecoder().decode(BossInboxDecision.self, from: Data(json.utf8))
        XCTAssertNil(decoded.triage)
        XCTAssertTrue(decoded.isOpenForTriage(at: Date()))
    }

    func testWorkspaceStateWithPreTriageDecisionLogLoadsAsOpenInbox() throws {
        // An entire persisted workspace whose decisionLog rows predate triage
        // loads with every escalate open in the inbox — old state → open.
        let entryId = UUID().uuidString
        let json = """
        {"schemaVersion":1,"boss":{"agentName":"slugger","scope":"machine"},"projects":[],"processEntries":[],"processRuns":[],"actionLog":[],"decisionLog":[{"id":"\(UUID().uuidString)","occurredAt":0,"source":"boss","entryId":"\(entryId)","sessionName":"Codex","prompt":"Choose? (1/2)","kind":"escalate","reasoning":"no pref","status":"recorded"}],"updatedAt":0}
        """
        let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(json.utf8))
        XCTAssertEqual(state.decisionLog.count, 1)
        XCTAssertNil(state.decisionLog[0].triage)
        XCTAssertEqual(state.openInbox(now: Date()).count, 1, "a pre-triage escalation is open in the inbox")
    }

    func testTriageRoundTripsThroughWorkspaceState() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        var state = WorkspaceState()
        let d = escalate(prompt: "Snooze me? (y/N)", at: now)
        state.recordDecision(d)
        state.snooze(decisionID: d.id, until: now.addingTimeInterval(3600))

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: data)
        XCTAssertEqual(decoded.decisionLog.first?.triage, .snoozed(until: now.addingTimeInterval(3600)), "triage survives a persistence round-trip")
    }

    func testAcknowledgedAndResolvedTriageRoundTripAndDefaultMissingDates() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        for triage in [DecisionTriage.acknowledged(at: now), .resolved(at: now)] {
            let data = try JSONEncoder().encode(triage)
            let decoded = try JSONDecoder().decode(DecisionTriage.self, from: data)
            XCTAssertEqual(decoded, triage)
        }

        let acknowledgedWithoutDate = try JSONDecoder().decode(DecisionTriage.self, from: Data(#"{"state":"acknowledged"}"#.utf8))
        if case .acknowledged = acknowledgedWithoutDate {
            XCTAssertFalse(acknowledgedWithoutDate.isOpen(at: Date()))
        } else {
            XCTFail("expected acknowledged default date")
        }

        let resolvedWithoutDate = try JSONDecoder().decode(DecisionTriage.self, from: Data(#"{"state":"resolved"}"#.utf8))
        if case .resolved = resolvedWithoutDate {
            XCTAssertFalse(resolvedWithoutDate.isOpen(at: Date()))
        } else {
            XCTFail("expected resolved default date")
        }
    }

    // MARK: - Snooze interval helper

    func testUntilEndOfDayReturnsSecondsToNextMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 2026-06-03 22:00:00 UTC → next midnight is 2026-06-04 00:00:00 UTC = 2h.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 3
        comps.hour = 22; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        let now = calendar.date(from: comps)!
        let interval = WorkbenchTriageInterval.untilEndOfDay(now: now, calendar: calendar)
        XCTAssertEqual(interval, 2 * 3600, accuracy: 1, "two hours until the next midnight")
    }

    func testUntilEndOfDayIsAtLeastAMinute() {
        // Right before midnight, the interval is clamped so a snooze isn't a no-op.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 3
        comps.hour = 23; comps.minute = 59; comps.second = 30
        comps.timeZone = TimeZone(identifier: "UTC")
        let now = calendar.date(from: comps)!
        XCTAssertGreaterThanOrEqual(WorkbenchTriageInterval.untilEndOfDay(now: now, calendar: calendar), 60)
    }

    func testDecisionTriageCorruptStateDecodesToResolved() throws {
        // A triage blob with an unrecognized `state` decodes to resolved
        // (out-of-queue, safe) rather than throwing and dropping the whole row.
        let json = """
        {"id":"\(UUID().uuidString)","occurredAt":0,"source":"boss","prompt":"p","kind":"escalate","reasoning":"r","status":"recorded","triage":{"state":"teleported","at":0}}
        """
        let decoded = try JSONDecoder().decode(BossInboxDecision.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.isOpenForTriage(at: Date()), "an unknown triage state is treated as out-of-queue, not a crash")
    }

    // MARK: - FIX 1: cap never evicts an open escalation

    /// Build a RESOLVED (out-of-queue) escalation that the cap is free to drop.
    private func resolvedEscalation(prompt: String, at: Date) -> BossInboxDecision {
        BossInboxDecision(
            occurredAt: at, source: "boss", entryId: UUID(), sessionName: "s",
            prompt: prompt, kind: .escalate, reasoning: "r", triage: .resolved(at: at)
        )
    }

    /// An OPEN escalation (no triage) — the kind `openInbox` surfaces and the
    /// cap must never silently drop.
    private func openEscalation(prompt: String, at: Date) -> BossInboxDecision {
        BossInboxDecision(
            occurredAt: at, source: "boss", entryId: UUID(), sessionName: "s",
            prompt: prompt, kind: .escalate, reasoning: "r"
        )
    }

    func testCapEvictsResolvedBeforeOpenEscalation() {
        let now = Date()
        var state = WorkspaceState()
        // Fill PAST the cap entirely with resolved rows, then bury a single open
        // escalation older than the cap's worth of newer resolved rows. The
        // unconditional removeLast would evict the buried open one; the fix must
        // keep it and shed resolved rows instead.
        let open = openEscalation(prompt: "Needs you? (y/N)", at: now.addingTimeInterval(-10_000))
        state.recordDecision(open)
        for i in 0..<(WorkspaceState.decisionLogCap + 50) {
            state.recordDecision(resolvedEscalation(prompt: "old-\(i)", at: now.addingTimeInterval(Double(i))))
        }
        XCTAssertEqual(state.decisionLog.count, WorkspaceState.decisionLogCap, "still bounded to the cap")
        XCTAssertTrue(
            state.decisionLog.contains(where: { $0.id == open.id }),
            "an open escalation is never evicted by the cap; resolved rows are shed first"
        )
        XCTAssertTrue(
            state.openInbox(now: now).contains(where: { $0.id == open.id }),
            "the surviving open escalation still surfaces in the inbox"
        )
    }

    func testCapKeepsAllOpenEscalationsWhenEveryEntryIsOpen() {
        let now = Date()
        var state = WorkspaceState()
        // Boundary: every row is an OPEN escalation. None may be evicted, so the
        // log is allowed to exceed the cap (bounded by live sessions in practice)
        // rather than silently drop a waiting session.
        var ids: [UUID] = []
        for i in 0..<(WorkspaceState.decisionLogCap + 10) {
            let d = openEscalation(prompt: "open-\(i)? (y/N)", at: now.addingTimeInterval(Double(i)))
            ids.append(d.id)
            state.recordDecision(d)
        }
        XCTAssertEqual(state.decisionLog.count, WorkspaceState.decisionLogCap + 10, "open items are retained beyond the cap rather than dropped")
        XCTAssertEqual(Set(state.decisionLog.map(\.id)), Set(ids), "no open escalation was evicted")
    }

    func testCapEvictsOldestResolvedFirstWhenOverByOne() {
        let now = Date()
        var state = WorkspaceState()
        // Exactly cap resolved rows, then one more resolved → the single OLDEST
        // resolved is evicted (oldest-first), newest preserved.
        var ordered: [BossInboxDecision] = []
        for i in 0..<(WorkspaceState.decisionLogCap + 1) {
            let d = resolvedEscalation(prompt: "r-\(i)", at: now.addingTimeInterval(Double(i)))
            ordered.append(d)
            state.recordDecision(d)
        }
        XCTAssertEqual(state.decisionLog.count, WorkspaceState.decisionLogCap)
        XCTAssertFalse(state.decisionLog.contains(where: { $0.id == ordered.first?.id }), "the single oldest resolved row is shed")
        XCTAssertEqual(state.decisionLog.first?.id, ordered.last?.id, "newest is preserved at the head")
    }

    func testTrimmedToCapIsPureAndPrefersEvictingResolved() {
        let now = Date()
        // Pure-function contract: given an over-cap log with a mix, evict resolved
        // oldest-first and keep every open entry, capped only when all are open.
        let openOld = openEscalation(prompt: "open-old? (y/N)", at: now.addingTimeInterval(-100))
        let resolvedMid = resolvedEscalation(prompt: "res-mid", at: now.addingTimeInterval(-50))
        let openNew = openEscalation(prompt: "open-new? (y/N)", at: now)
        // Newest-first log of 3 with cap 2: must drop the lone resolved, keep both open.
        let log = [openNew, resolvedMid, openOld]
        let trimmed = WorkspaceState.trimmedToCap(log, cap: 2, now: now)
        XCTAssertEqual(trimmed.map(\.id), [openNew.id, openOld.id], "resolved evicted; both open kept even though that holds at the cap")
    }
}
