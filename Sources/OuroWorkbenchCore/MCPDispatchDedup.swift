import Foundation
import CryptoKit

/// F10a cold-review regression fix (HIGH). The dispatch chokepoint used to key its
/// dedup purely on the JSON-RPC envelope `id` and cache EVERY method's response for
/// the server's lifetime. But JSON-RPC / MCP only require `id` uniqueness among
/// SIMULTANEOUSLY-OUTSTANDING requests — reuse after a response is spec-compliant
/// (this codebase's own `BossAgentMCPClient` recycles `id:1`/`id:2` on every call).
/// So a recycled id for a DIFFERENT request replayed the STALE cached result of an
/// unrelated tool (e.g. a `workbench_sessions` call replaying an old
/// `workbench_status` payload).
///
/// Two corrections, both pure and behaviorally testable here in Core (the wiring
/// over `handle(line:)` can only be source-grepped, which is where the bug hid):
///  1. **Scope dedup to side-effecting tools only** (`MCPDedupEligibility`). Reads +
///     handshakes always process FRESH — caching a read replays stale data on a
///     re-read.
///  2. **Key on request IDENTITY** (`MCPRequestKey.identity`): envelope id + method
///     + a stable hash of params. A reused id with different content is a distinct
///     key, so it never replays the wrong response; a byte-identical retry still
///     replays the original ack.

// MARK: - Eligibility

/// Classifies an MCP method/tool as side-effecting (consults + populates the dedup
/// ledger) vs a read/handshake (always processes fresh, never cached).
///
/// The side-effecting set is the tools whose dispatch handler MUTATES durable state
/// — every one enqueues to `WorkbenchActionRequestQueue` or `AgentProposalQueue`
/// (audited against the dispatch switch's `enqueue` sites). Everything else —
/// `initialize`, `tools/list`, and every read/query tool — is idempotent and must
/// re-run so a re-read returns LIVE state, never a stale cached payload.
public enum MCPDedupEligibility {
    /// The exact set of state-mutating `tools/call` tool names. Each one enqueues an
    /// auditable action (`request_action`/`create_session`/`report_bug`) or a
    /// proposal (`propose`); a byte-identical retry of one of these must re-ack with
    /// its ORIGINAL response rather than double-execute.
    public static let sideEffectingTools: Set<String> = [
        "workbench_request_action",
        "workbench_create_session",
        "workbench_report_bug",
        "workbench_propose"
    ]

    /// Whether a dispatched method (and, for `tools/call`, its tool name) mutates
    /// state and therefore participates in dedup. `initialize`, `tools/list`, every
    /// read tool, an unknown tool, and a `tools/call` with no resolvable name all
    /// return `false` (process fresh, never cache).
    public static func isSideEffecting(method: String, toolName: String?) -> Bool {
        guard method == "tools/call", let toolName else {
            return false
        }
        return sideEffectingTools.contains(toolName)
    }
}

// MARK: - Decision

/// The decision the dispatch chokepoint acts on for one observed request. Not
/// `Equatable` — call sites (the chokepoint and tests) pattern-match the arms with
/// `case`, so no value equality is needed.
public enum DispatchDedupDecision {
    /// A read/handshake (or a request with no usable identity): process fresh,
    /// bypassing the ledger entirely (never consulted, never populated).
    case passThroughFresh
    /// A side-effecting first sight (or a released slot): run the handler, then
    /// `complete(...)` the ledger.
    case proceed
    /// A side-effecting byte-identical duplicate that already completed: replay the
    /// ORIGINAL response verbatim (carrying the original request.id), never re-run.
    case replayCached(MCPDedupCachedResponse)
    /// A side-effecting duplicate observed while the original is still running:
    /// reject rather than double-execute.
    case rejectInFlight
}

// MARK: - The pure chokepoint seam

/// The pure dedup decision for the dispatch chokepoint. Given a parsed JSON-RPC
/// request, the eligibility classifier, and the ledger, it returns the decision
/// plus the next ledger state. `handle(line:)` becomes thin wiring over this.
public enum MCPDispatchDedup {
    /// Classify an observed request and return `(decision, nextLedger)`.
    ///  - A read/handshake → `.passThroughFresh`, ledger UNCHANGED (never consulted).
    ///  - A side-effecting request with no usable identity → `.passThroughFresh`
    ///    (can't be keyed; must still run).
    ///  - A side-effecting request with an identity → delegate to the ledger:
    ///    `.proceed` (records in-flight) / `.replayCached` / `.rejectInFlight`.
    public static func decide(
        request: [String: Any],
        ledger: MCPRequestDedupLedger,
        now: Date
    ) -> (decision: DispatchDedupDecision, ledger: MCPRequestDedupLedger) {
        let method = request["method"] as? String
        let toolName = toolName(of: request)
        guard let method, MCPDedupEligibility.isSideEffecting(method: method, toolName: toolName) else {
            // Reads + handshakes never touch the ledger.
            return (.passThroughFresh, ledger)
        }
        guard let key = MCPRequestKey.identity(from: request) else {
            // Side-effecting but unkeyable (no usable envelope id): run it fresh.
            return (.passThroughFresh, ledger)
        }
        let (ledgerDecision, next) = ledger.observe(key: key, now: now)
        switch ledgerDecision {
        case .proceed:
            return (.proceed, next)
        case let .replayCached(response):
            return (.replayCached(response), next)
        case .rejectInFlight:
            return (.rejectInFlight, next)
        }
    }

    /// Finish a previously-`.proceed`ed side-effecting request. A read/handshake (or
    /// an unkeyable request) is a no-op — it never entered the ledger, so there is
    /// nothing to complete (and a read must NEVER be cached). `response == nil`
    /// RELEASES the slot for a transient/thrown retry; non-nil caches the final ack.
    public static func complete(
        request: [String: Any],
        response: MCPDedupCachedResponse?,
        ledger: MCPRequestDedupLedger,
        now: Date
    ) -> MCPRequestDedupLedger {
        let method = request["method"] as? String
        let toolName = toolName(of: request)
        guard let method, MCPDedupEligibility.isSideEffecting(method: method, toolName: toolName),
              let key = MCPRequestKey.identity(from: request) else {
            return ledger
        }
        return ledger.complete(key: key, response: response, now: now)
    }

    /// The `tools/call` tool name, or `nil` for a non-`tools/call` method or a
    /// malformed params object.
    private static func toolName(of request: [String: Any]) -> String? {
        guard (request["method"] as? String) == "tools/call",
              let params = request["params"] as? [String: Any] else {
            return nil
        }
        return params["name"] as? String
    }
}

// MARK: - Stable params hash for the request-IDENTITY key

extension MCPRequestKey {
    /// Derive the dedup IDENTITY key from a full parsed JSON-RPC request: the
    /// envelope `id` (normalized via `from(rawID:)`) folded together with the
    /// `method` and a STABLE hash of the `params`. Returns `nil` when there is no
    /// usable envelope id (a notification) or no method — both bypass dedup.
    ///
    /// Folding method + params means a recycled id with DIFFERENT content is a
    /// DISTINCT key (so it can never replay an unrelated response), while a
    /// byte-identical retry (same id+method+params, in any key order) hashes to the
    /// SAME key and replays its original response.
    public static func identity(from request: [String: Any]) -> MCPRequestKey? {
        guard let envelope = MCPRequestKey.from(rawID: request["id"]),
              let method = request["method"] as? String else {
            return nil
        }
        let paramsHash = MCPRequestKey.stableHash(of: request["params"])
        // Re-encode the composite as the existing `.string` case so the ledger's
        // Hashable key type is unchanged — the identity is a single canonical string
        // that varies with id, method, AND params.
        return .string("\(MCPRequestKey.scalar(of: envelope))\u{1F}\(method)\u{1F}\(paramsHash)")
    }

    /// The canonical scalar form of a normalized envelope key, tagged by kind so the
    /// string id "1" and the number id 1 stay distinct (matching
    /// `from(rawID:)`'s contract).
    private static func scalar(of key: MCPRequestKey) -> String {
        switch key {
        case let .string(value):
            return "s:\(value)"
        case let .number(value):
            return "n:\(value)"
        }
    }

    /// A deterministic, order-independent hash of a JSON `params` value. Re-serializes
    /// with `.sortedKeys` so two byte-identical params (in any key order) produce the
    /// same digest, then SHA-256s the bytes. A `nil`/unserializable params hashes to a
    /// fixed sentinel — two paramless requests are identical there, which is correct.
    private static func stableHash(of params: Any?) -> String {
        guard let params else {
            return "0"
        }
        guard JSONSerialization.isValidJSONObject(params),
              let data = try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]) else {
            // A non-object params (or one that won't serialize) still needs a stable,
            // content-derived tag; fall back to its description bytes.
            return SHA256.hashString(of: Data("\(params)".utf8))
        }
        return SHA256.hashString(of: data)
    }
}

private extension SHA256 {
    /// Hex digest of arbitrary bytes — the stable content tag for a params blob.
    static func hashString(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
