import XCTest
@testable import OuroWorkbenchCore

/// F10a Core seam 1: the JSON-RPC envelope-id dedup ledger. This is a DISTINCT
/// layer from the action-fingerprint dedup in WorkbenchActionRequestQueue — it
/// keys on the JSON-RPC request `id` so a retried/replayed/reconnected request
/// with the SAME id does not re-execute a side-effecting handler, and a dropped
/// duplicate replays the ORIGINAL response (carrying the original request.id
/// UUID) instead of minting a fresh one.
///
/// The ledger is a pure value type with NO `Date()` inside — `now` is injected at
/// every mutating call so eviction recency is deterministic in tests. The `var`
/// field on the wiring site is not thread-safe by design (today's run loop is
/// synchronous); a future concurrent rewrite would wrap it in an actor.
final class MCPRequestDedupLedgerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    // MARK: - MCPRequestKey.from(rawID:)

    func testKeyFromString() {
        XCTAssertEqual(MCPRequestKey.from(rawID: "abc"), .string("abc"))
    }

    func testKeyFromInt() {
        XCTAssertEqual(MCPRequestKey.from(rawID: 7), .number(7))
    }

    func testKeyFromNilIsNil() {
        // A notification (no id) bypasses dedup structurally.
        XCTAssertNil(MCPRequestKey.from(rawID: nil))
    }

    func testKeyFromNSNullIsNil() {
        XCTAssertNil(MCPRequestKey.from(rawID: NSNull()))
    }

    func testKeyFromUnexpectedTypeIsNil() {
        // A dictionary/array id is not a valid JSON-RPC scalar id for us.
        XCTAssertNil(MCPRequestKey.from(rawID: ["nested": 1]))
    }

    func testKeyFromBoolIsNil() {
        // JSONSerialization bridges a JSON bool to NSNumber too — but a bool id
        // is not a valid scalar id, so it must be rejected (not coerced to 0/1).
        XCTAssertNil(MCPRequestKey.from(rawID: true))
        XCTAssertNil(MCPRequestKey.from(rawID: false))
    }

    func testStringAndNumberKeysAreDistinct() {
        // "1" (string) and 1 (number) are different JSON-RPC ids.
        XCTAssertNotEqual(MCPRequestKey.from(rawID: "1"), MCPRequestKey.from(rawID: 1))
    }

    // MARK: - observe: first sight proceeds

    func testFirstObserveProceeds() {
        let ledger = MCPRequestDedupLedger()
        let (decision, _) = ledger.observe(key: .string("a"), now: at(0))
        guard case .proceed = decision else {
            return XCTFail("first sight of a key must proceed, got \(decision)")
        }
    }

    func testDistinctKeysBothProceed() {
        var ledger = MCPRequestDedupLedger()
        let (d1, l1) = ledger.observe(key: .string("a"), now: at(0))
        ledger = l1
        let (d2, _) = ledger.observe(key: .number(2), now: at(1))
        guard case .proceed = d1, case .proceed = d2 else {
            return XCTFail("distinct keys must each proceed")
        }
    }

    // MARK: - observe of an in-flight key rejects

    func testObserveWhileInFlightRejects() {
        var ledger = MCPRequestDedupLedger()
        let (_, afterObserve) = ledger.observe(key: .string("a"), now: at(0))
        ledger = afterObserve
        // Same key observed again BEFORE complete(): the original is still
        // running, so the retry must be rejected (not double-executed).
        let (decision, _) = ledger.observe(key: .string("a"), now: at(1))
        guard case .rejectInFlight = decision else {
            return XCTFail("a second observe before complete must rejectInFlight, got \(decision)")
        }
    }

    // MARK: - complete then re-observe replays the cached response

    func testCompletedKeyReplaysCachedResponse() {
        var ledger = MCPRequestDedupLedger()
        let cached = MCPDedupCachedResponse(payload: ["jsonrpc": "2.0", "id": "orig-uuid", "result": ["ok": true]])
        let (_, afterObserve) = ledger.observe(key: .string("a"), now: at(0))
        ledger = afterObserve
        ledger = ledger.complete(key: .string("a"), response: cached, now: at(1))

        let (decision, _) = ledger.observe(key: .string("a"), now: at(2))
        guard case let .replayCached(response) = decision else {
            return XCTFail("a completed key must replayCached, got \(decision)")
        }
        // The replay carries the ORIGINAL response verbatim — same id UUID.
        XCTAssertEqual(response.payload["id"] as? String, "orig-uuid")
    }

    // MARK: - complete with release (transient/thrown) frees the slot for retry

    func testCompleteReleaseAllowsRetryToProceed() {
        var ledger = MCPRequestDedupLedger()
        let (_, afterObserve) = ledger.observe(key: .string("a"), now: at(0))
        ledger = afterObserve
        // A thrown/transient handler RELEASES the in-flight slot — it must NOT
        // cache a transient failure as the permanent answer. The retry proceeds.
        ledger = ledger.complete(key: .string("a"), response: nil, now: at(1))

        let (decision, _) = ledger.observe(key: .string("a"), now: at(2))
        guard case .proceed = decision else {
            return XCTFail("after a release-complete, a retry must proceed, got \(decision)")
        }
    }

    // MARK: - complete on an unknown key is a harmless no-op

    func testCompleteOnUnknownKeyIsNoOp() {
        let ledger = MCPRequestDedupLedger()
        // Defensive: complete() before observe() (shouldn't happen with the
        // one-exit wiring, but must not crash or wedge the ledger).
        let after = ledger.complete(key: .string("ghost"), response: nil, now: at(0))
        let (decision, _) = after.observe(key: .string("ghost"), now: at(1))
        guard case .proceed = decision else {
            return XCTFail("a key only ever seen by complete() must still proceed on first observe")
        }
    }

    // MARK: - eviction: FIFO by injected now, never evicts in-flight

    func testEvictionDropsOldestCompletedWhenOverCapacity() {
        var ledger = MCPRequestDedupLedger(capacity: 2)
        let cached: (String) -> MCPDedupCachedResponse = { id in
            MCPDedupCachedResponse(payload: ["id": id])
        }
        // Fill to capacity with two completed entries.
        ledger = ledger.observe(key: .string("a"), now: at(0)).1
        ledger = ledger.complete(key: .string("a"), response: cached("a"), now: at(1))
        ledger = ledger.observe(key: .string("b"), now: at(2)).1
        ledger = ledger.complete(key: .string("b"), response: cached("b"), now: at(3))
        // A third completed entry overflows capacity 2 — oldest ("a") is evicted.
        ledger = ledger.observe(key: .string("c"), now: at(4)).1
        ledger = ledger.complete(key: .string("c"), response: cached("c"), now: at(5))

        // "a" is gone: re-observe proceeds (no longer cached).
        let (decisionA, _) = ledger.observe(key: .string("a"), now: at(6))
        guard case .proceed = decisionA else {
            return XCTFail("evicted oldest key must proceed on re-observe, got \(decisionA)")
        }
        // "b" and "c" remain cached: re-observe replays.
        let (decisionB, _) = ledger.observe(key: .string("b"), now: at(7))
        let (decisionC, _) = ledger.observe(key: .string("c"), now: at(8))
        guard case .replayCached = decisionB, case .replayCached = decisionC else {
            return XCTFail("surviving keys must replayCached")
        }
    }

    func testEvictionNeverEvictsInFlightEntry() {
        var ledger = MCPRequestDedupLedger(capacity: 2)
        let cached: (String) -> MCPDedupCachedResponse = { id in
            MCPDedupCachedResponse(payload: ["id": id])
        }
        // "a" is observed but NOT completed — it is in-flight.
        ledger = ledger.observe(key: .string("a"), now: at(0)).1
        // Two more completed entries arrive, exceeding capacity.
        ledger = ledger.observe(key: .string("b"), now: at(1)).1
        ledger = ledger.complete(key: .string("b"), response: cached("b"), now: at(2))
        ledger = ledger.observe(key: .string("c"), now: at(3)).1
        ledger = ledger.complete(key: .string("c"), response: cached("c"), now: at(4))

        // Eviction must spare the in-flight "a": a retry of "a" still rejects
        // (the original is running) — it was NOT silently dropped.
        let (decisionA, _) = ledger.observe(key: .string("a"), now: at(5))
        guard case .rejectInFlight = decisionA else {
            return XCTFail("in-flight entry must never be evicted; retry must rejectInFlight, got \(decisionA)")
        }
    }

    func testEvictionUsesInjectedRecencyNotInsertionAmbiguity() {
        // Determinism: eviction order follows the injected `now` of completion.
        // Complete "a" at a LATER now than "b" even though "a" was observed
        // first — "b" (older completion) is the eviction victim.
        var ledger = MCPRequestDedupLedger(capacity: 2)
        let cached: (String) -> MCPDedupCachedResponse = { id in
            MCPDedupCachedResponse(payload: ["id": id])
        }
        ledger = ledger.observe(key: .string("a"), now: at(0)).1
        ledger = ledger.observe(key: .string("b"), now: at(1)).1
        // "b" completes first (older), "a" completes second (newer).
        ledger = ledger.complete(key: .string("b"), response: cached("b"), now: at(2))
        ledger = ledger.complete(key: .string("a"), response: cached("a"), now: at(3))
        // Overflow with "c": the oldest COMPLETION is "b", so "b" is evicted.
        ledger = ledger.observe(key: .string("c"), now: at(4)).1
        ledger = ledger.complete(key: .string("c"), response: cached("c"), now: at(5))

        let (decisionB, _) = ledger.observe(key: .string("b"), now: at(6))
        let (decisionA, _) = ledger.observe(key: .string("a"), now: at(7))
        guard case .proceed = decisionB else {
            return XCTFail("oldest-completion key must be evicted, got \(decisionB)")
        }
        guard case .replayCached = decisionA else {
            return XCTFail("newer-completion key must survive, got \(decisionA)")
        }
    }

    func testDefaultCapacityIs256() {
        XCTAssertEqual(MCPRequestDedupLedger().capacity, 256)
    }
}
