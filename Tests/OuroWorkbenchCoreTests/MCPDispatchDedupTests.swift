import XCTest
@testable import OuroWorkbenchCore

/// F10a cold-review regression fix (HIGH): the dispatch-chokepoint dedup decision,
/// extracted as a pure Core seam so a real TWO-REQUEST SEQUENCE is unit-testable
/// (the wiring tests can only grep `handle(line:)` — they can't execute it, which
/// is exactly where the id-only/all-method cache bug hid).
///
/// Two behavioral fixes are pinned here:
///  1. Dedup is scoped to SIDE-EFFECTING tools ONLY. Reads + handshakes
///     (`initialize`, `tools/list`, `workbench_status`, `workbench_sessions`, …)
///     always process fresh — caching a read replays STALE data on a re-read.
///  2. The ledger key is the request IDENTITY (envelope id + method + a stable
///     hash of params), NOT the bare envelope id. A recycled id with DIFFERENT
///     content is a DISTINCT key, so it never replays an unrelated response.
final class MCPDispatchDedupTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 2_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    // Build a `tools/call` request dict the way JSONSerialization hands it over.
    private func toolCall(id: Any, name: String, arguments: [String: Any] = [:]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
    }

    private func cached(_ id: Any) -> MCPDedupCachedResponse {
        MCPDedupCachedResponse(payload: ["jsonrpc": "2.0", "id": id, "result": ["marker": "\(id)"]])
    }

    // MARK: - Eligibility: only the four audited side-effecting tools dedup

    func testInitializeIsNotSideEffecting() {
        XCTAssertFalse(MCPDedupEligibility.isSideEffecting(method: "initialize", toolName: nil))
    }

    func testToolsListIsNotSideEffecting() {
        XCTAssertFalse(MCPDedupEligibility.isSideEffecting(method: "tools/list", toolName: nil))
    }

    func testReadToolsAreNotSideEffecting() {
        for read in [
            "workbench_status", "workbench_onboarding_status", "workbench_autonomy_readiness",
            "workbench_sessions", "workbench_attention_queue", "workbench_action_result",
            "workbench_visibility", "workbench_sense", "workbench_transcript_tail",
            "workbench_session_health", "workbench_search_transcripts", "workbench_recovery_drill",
            "workbench_discover_agent_sessions", "workbench_proposal_result"
        ] {
            XCTAssertFalse(
                MCPDedupEligibility.isSideEffecting(method: "tools/call", toolName: read),
                "\(read) is a read/query and must NOT dedup"
            )
        }
    }

    func testOnlyTheFourMutatingToolsAreSideEffecting() {
        for mutating in ["workbench_request_action", "workbench_create_session", "workbench_report_bug", "workbench_propose"] {
            XCTAssertTrue(
                MCPDedupEligibility.isSideEffecting(method: "tools/call", toolName: mutating),
                "\(mutating) mutates state and MUST dedup"
            )
        }
    }

    func testUnknownToolIsNotSideEffecting() {
        // An unknown tool name never enqueues (it throws Unknown tool upstream),
        // so it must not be cached either — default to fresh.
        XCTAssertFalse(MCPDedupEligibility.isSideEffecting(method: "tools/call", toolName: "totally_unknown"))
    }

    func testToolsCallWithNoNameIsNotSideEffecting() {
        XCTAssertFalse(MCPDedupEligibility.isSideEffecting(method: "tools/call", toolName: nil))
    }

    // MARK: - Identity key folds method + params, not just the envelope id

    func testSameIdDifferentToolYieldsDistinctKeys() throws {
        let a = try XCTUnwrap(MCPRequestKey.identity(from: toolCall(id: 2, name: "workbench_status")))
        let b = try XCTUnwrap(MCPRequestKey.identity(from: toolCall(id: 2, name: "workbench_sessions")))
        XCTAssertNotEqual(a, b, "same envelope id but different tool must be DISTINCT identities")
    }

    func testSameIdDifferentParamsYieldsDistinctKeys() throws {
        let a = try XCTUnwrap(MCPRequestKey.identity(from: toolCall(id: 5, name: "workbench_request_action", arguments: ["action": "recover", "entry": "one"])))
        let b = try XCTUnwrap(MCPRequestKey.identity(from: toolCall(id: 5, name: "workbench_request_action", arguments: ["action": "recover", "entry": "two"])))
        XCTAssertNotEqual(a, b, "same id+method but different params must be DISTINCT identities")
    }

    func testByteIdenticalRequestYieldsSameKey() throws {
        // Stable: params hash must not depend on dictionary iteration order.
        let a = try XCTUnwrap(MCPRequestKey.identity(from: toolCall(id: 5, name: "workbench_request_action", arguments: ["action": "recover", "entry": "x", "trust": "trusted"])))
        let b = try XCTUnwrap(MCPRequestKey.identity(from: toolCall(id: 5, name: "workbench_request_action", arguments: ["trust": "trusted", "entry": "x", "action": "recover"])))
        XCTAssertEqual(a, b, "a byte-identical retry (same id+method+params, any key order) must hash to the SAME identity")
    }

    func testNotificationHasNoIdentity() {
        XCTAssertNil(MCPRequestKey.identity(from: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
    }

    func testRequestWithoutMethodHasNoIdentity() {
        XCTAssertNil(MCPRequestKey.identity(from: ["jsonrpc": "2.0", "id": 1]))
    }

    func testStringEnvelopeIdIsTaggedDistinctlyFromNumberId() throws {
        // The string id "2" and the number id 2 must yield DISTINCT identities even
        // for the same method+params (matching from(rawID:)'s string-vs-number
        // contract) — so the envelope scalar carries its kind tag.
        let stringId = try XCTUnwrap(MCPRequestKey.identity(from: toolCall(id: "2", name: "workbench_request_action", arguments: ["action": "recover"])))
        let numberId = try XCTUnwrap(MCPRequestKey.identity(from: toolCall(id: 2, name: "workbench_request_action", arguments: ["action": "recover"])))
        XCTAssertNotEqual(stringId, numberId, "a string id and a number id are different JSON-RPC ids → distinct identities")
    }

    func testStringEnvelopeIdRetryReplaysOriginal() {
        // A side-effecting call keyed on a STRING envelope id still dedups a
        // byte-identical retry (exercises the .string envelope path end-to-end).
        var ledger = MCPRequestDedupLedger()
        let req = toolCall(id: "req-abc", name: "workbench_propose", arguments: ["title": "t", "items": []])
        let first = MCPDispatchDedup.decide(request: req, ledger: ledger, now: at(0))
        guard case .proceed = first.decision else { return XCTFail("first must proceed") }
        ledger = MCPDispatchDedup.complete(request: req, response: cached("ack-str"), ledger: first.ledger, now: at(1))
        let retry = MCPDispatchDedup.decide(request: req, ledger: ledger, now: at(2))
        guard case let .replayCached(payload) = retry.decision else {
            return XCTFail("a byte-identical string-id retry must replayCached, got \(retry.decision)")
        }
        XCTAssertEqual(payload.payload["id"] as? String, "ack-str")
    }

    func testParamlessSideEffectingRequestsHashIdentically() throws {
        // Two paramless requests with the same id+method hash to the SAME identity
        // (the params-absent sentinel) — exercises the nil-params branch.
        let a = try XCTUnwrap(MCPRequestKey.identity(from: ["jsonrpc": "2.0", "id": 4, "method": "tools/call"]))
        let b = try XCTUnwrap(MCPRequestKey.identity(from: ["jsonrpc": "2.0", "id": 4, "method": "tools/call"]))
        XCTAssertEqual(a, b, "paramless requests with same id+method must share an identity")
    }

    func testParamlessVsParamfulDifferIdentities() throws {
        // The params-absent sentinel must differ from any real params hash.
        let none = try XCTUnwrap(MCPRequestKey.identity(from: ["jsonrpc": "2.0", "id": 4, "method": "tools/call"]))
        let some = try XCTUnwrap(MCPRequestKey.identity(from: toolCall(id: 4, name: "workbench_status")))
        XCTAssertNotEqual(none, some, "absent params must not collide with a present params hash")
    }

    func testNonObjectParamsHashStablyByContent() throws {
        // A params value that is not a top-level JSON object/array (here: a bare
        // scalar string, which JSONSerialization.isValidJSONObject rejects) still
        // gets a stable, content-derived identity via the description fallback —
        // same content → same identity, different content → different.
        let a = try XCTUnwrap(MCPRequestKey.identity(from: ["jsonrpc": "2.0", "id": 8, "method": "weird", "params": "scalar-params"]))
        let b = try XCTUnwrap(MCPRequestKey.identity(from: ["jsonrpc": "2.0", "id": 8, "method": "weird", "params": "scalar-params"]))
        let c = try XCTUnwrap(MCPRequestKey.identity(from: ["jsonrpc": "2.0", "id": 8, "method": "weird", "params": "other-params"]))
        XCTAssertEqual(a, b, "identical non-object params must hash identically")
        XCTAssertNotEqual(a, c, "different non-object params must hash differently")
    }

    // MARK: - The headline corruption: a read re-using an id never replays a stale read

    func testReadThenSameIdDifferentReadProcessesFresh() {
        // workbench_status with id:2 processed and "completed"; then the SAME id:2
        // reused for workbench_sessions. The second MUST proceed fresh — it must
        // NOT be served the status payload.
        var ledger = MCPRequestDedupLedger()

        let first = MCPDispatchDedup.decide(
            request: toolCall(id: 2, name: "workbench_status"), ledger: ledger, now: at(0)
        )
        guard case .passThroughFresh = first.decision else {
            return XCTFail("a read must passThroughFresh, got \(first.decision)")
        }
        ledger = first.ledger
        // Even if some buggy path tried to complete() it, a read never touches the ledger.
        ledger = MCPDispatchDedup.complete(
            request: toolCall(id: 2, name: "workbench_status"), response: cached(2), ledger: ledger, now: at(1)
        )

        let second = MCPDispatchDedup.decide(
            request: toolCall(id: 2, name: "workbench_sessions"), ledger: ledger, now: at(2)
        )
        guard case .passThroughFresh = second.decision else {
            return XCTFail("a different read reusing the id must passThroughFresh (never replay the first read), got \(second.decision)")
        }
    }

    func testReadReissuedWithSameIdMethodParamsStillProcessesFresh() {
        // A read is NEVER cached, so an identical re-issue re-reads live state
        // (never a stale replay).
        var ledger = MCPRequestDedupLedger()
        let req = toolCall(id: 7, name: "workbench_status")

        let first = MCPDispatchDedup.decide(request: req, ledger: ledger, now: at(0))
        ledger = MCPDispatchDedup.complete(request: req, response: cached(7), ledger: first.ledger, now: at(1))

        let second = MCPDispatchDedup.decide(request: req, ledger: ledger, now: at(2))
        guard case .passThroughFresh = first.decision, case .passThroughFresh = second.decision else {
            return XCTFail("an identical read re-issue must process fresh both times, got \(first.decision)/\(second.decision)")
        }
    }

    // MARK: - Side-effecting retry replays its ORIGINAL response (the phantom-id fix)

    func testSideEffectingByteIdenticalRetryReplaysOriginal() {
        var ledger = MCPRequestDedupLedger()
        let req = toolCall(id: 2, name: "workbench_request_action", arguments: ["action": "recover", "entry": "alpha"])

        let first = MCPDispatchDedup.decide(request: req, ledger: ledger, now: at(0))
        guard case .proceed = first.decision else {
            return XCTFail("first sight of a side-effecting call must proceed, got \(first.decision)")
        }
        ledger = MCPDispatchDedup.complete(request: req, response: cached("orig-ack"), ledger: first.ledger, now: at(1))

        let retry = MCPDispatchDedup.decide(request: req, ledger: ledger, now: at(2))
        guard case let .replayCached(payload) = retry.decision else {
            return XCTFail("a byte-identical side-effecting retry must replayCached, got \(retry.decision)")
        }
        XCTAssertEqual(payload.payload["id"] as? String, "orig-ack", "the retry replays the ORIGINAL ack verbatim (no double-execute, no fresh id)")
    }

    func testSideEffectingDifferentParamsSameIdProceeds() {
        // id:5 request_action(recover alpha) processed; a DIFFERENT request_action
        // reusing id:5 (recover beta) must PROCEED — no cross-action collision.
        var ledger = MCPRequestDedupLedger()
        let a = toolCall(id: 5, name: "workbench_request_action", arguments: ["action": "recover", "entry": "alpha"])
        let b = toolCall(id: 5, name: "workbench_request_action", arguments: ["action": "recover", "entry": "beta"])

        let first = MCPDispatchDedup.decide(request: a, ledger: ledger, now: at(0))
        ledger = MCPDispatchDedup.complete(request: a, response: cached("ack-alpha"), ledger: first.ledger, now: at(1))

        let second = MCPDispatchDedup.decide(request: b, ledger: ledger, now: at(2))
        guard case .proceed = second.decision else {
            return XCTFail("a different side-effecting call reusing id:5 must PROCEED (not replay), got \(second.decision)")
        }
    }

    func testSideEffectingInFlightDuplicateRejects() {
        var ledger = MCPRequestDedupLedger()
        let req = toolCall(id: 9, name: "workbench_create_session", arguments: ["owner": "boss", "name": "s", "command": "claude"])

        let first = MCPDispatchDedup.decide(request: req, ledger: ledger, now: at(0))
        ledger = first.ledger // observed, NOT completed → in-flight
        let dup = MCPDispatchDedup.decide(request: req, ledger: ledger, now: at(1))
        guard case .rejectInFlight = dup.decision else {
            return XCTFail("a duplicate of an in-flight side-effecting call must rejectInFlight, got \(dup.decision)")
        }
    }

    // MARK: - A side-effecting transient (thrown) release frees the slot for retry

    func testSideEffectingReleaseAllowsRetryToProceed() {
        var ledger = MCPRequestDedupLedger()
        let req = toolCall(id: 3, name: "workbench_report_bug", arguments: ["note": "boom"])

        let first = MCPDispatchDedup.decide(request: req, ledger: ledger, now: at(0))
        // A thrown handler RELEASES (response: nil) — must not cache a transient failure.
        ledger = MCPDispatchDedup.complete(request: req, response: nil, ledger: first.ledger, now: at(1))

        let retry = MCPDispatchDedup.decide(request: req, ledger: ledger, now: at(2))
        guard case .proceed = retry.decision else {
            return XCTFail("after a release, a side-effecting retry must proceed, got \(retry.decision)")
        }
    }

    // MARK: - A request with no usable id passes through fresh (no dedup possible)

    func testToolsCallWithMissingParamsPassesThroughFresh() {
        // A `tools/call` whose params object is absent/malformed has no resolvable
        // tool name, so it is treated as not-side-effecting and processes fresh
        // (exercises the toolName(of:) nil arm via decide, not just isSideEffecting).
        let ledger = MCPRequestDedupLedger()
        let req: [String: Any] = ["jsonrpc": "2.0", "id": 11, "method": "tools/call"]
        let decision = MCPDispatchDedup.decide(request: req, ledger: ledger, now: at(0))
        guard case .passThroughFresh = decision.decision else {
            return XCTFail("a tools/call with no params must passThroughFresh, got \(decision.decision)")
        }
        // complete() on it is a harmless no-op (also drives the nil arm of toolName).
        let after = MCPDispatchDedup.complete(request: req, response: cached(11), ledger: decision.ledger, now: at(1))
        let again = MCPDispatchDedup.decide(request: req, ledger: after, now: at(2))
        guard case .passThroughFresh = again.decision else {
            return XCTFail("a no-params tools/call is never cached; must stay fresh, got \(again.decision)")
        }
    }

    func testSideEffectingWithNoIdPassesThroughFresh() {
        // A side-effecting call with no usable envelope id can't be keyed, so it
        // must process fresh rather than wedge.
        let ledger = MCPRequestDedupLedger()
        let req: [String: Any] = ["jsonrpc": "2.0", "method": "tools/call", "params": ["name": "workbench_propose", "arguments": ["title": "t", "items": []]]]
        let decision = MCPDispatchDedup.decide(request: req, ledger: ledger, now: at(0))
        guard case .passThroughFresh = decision.decision else {
            return XCTFail("a side-effecting call with no usable id must passThroughFresh, got \(decision.decision)")
        }
    }
}
