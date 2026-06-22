import Foundation

/// The JSON-RPC envelope `id` of a request, normalized to the only two scalar
/// shapes we accept. This is the dedup KEY for F10a's JSON-RPC-layer dedup —
/// distinct from `WorkbenchActionRequest.fingerprint`, which dedups by side
/// effect. Same-id retry is this layer's job; different-id same-effect is the
/// queue's.
public enum MCPRequestKey: Hashable, Sendable {
    case string(String)
    case number(Int)

    /// Normalize a raw JSON-RPC `id` to a key, or `nil` when the request has no
    /// usable id — `nil`/`NSNull` (a notification, which must bypass dedup
    /// structurally) or any non-scalar/unexpected value. Returning `nil` is the
    /// structural guarantee that notifications never enter the ledger.
    public static func from(rawID: Any?) -> MCPRequestKey? {
        switch rawID {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            // JSONSerialization bridges every JSON number AND every JSON bool to
            // NSNumber. A bool id is not a valid scalar id for us, so reject it;
            // a genuine integer becomes `.number`.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return nil
            }
            return .number(number.intValue)
        default:
            // nil, NSNull, dictionaries, arrays, anything else → no dedup.
            return nil
        }
    }
}

/// The decision the ledger hands back for an observed request id.
public enum DedupDecision {
    /// First sight (or a released slot): run the handler.
    case proceed
    /// A completed-and-cached duplicate: return the ORIGINAL response verbatim
    /// (carrying the original request.id), never re-run the handler.
    case replayCached(response: MCPDedupCachedResponse)
    /// A duplicate observed while the original is still running: reject rather
    /// than double-execute.
    case rejectInFlight
}

/// The cached JSON-RPC response payload for a completed request. Stored so a
/// duplicate replays byte-identically — crucially carrying the ORIGINAL
/// request.id, so a retried `request_action` reads back `applied` instead of a
/// freshly-minted `unknown` id.
public struct MCPDedupCachedResponse {
    public let payload: [String: Any]

    public init(payload: [String: Any]) {
        self.payload = payload
    }
}

/// F10a Core seam 1: a pure, deterministic dedup ledger keyed on the JSON-RPC
/// envelope `id`.
///
/// Purity: NO `Date()` inside — `now` is injected at every mutating call so
/// eviction recency is fully deterministic under test. Every mutator returns a
/// fresh value (`struct`), so the type is trivially copyable; the caller holds
/// it in a `var`. NOTE: that `var` is **not** thread-safe. Today's MCP run loop
/// is a synchronous `readLine` loop, so concurrent access can't occur and
/// `.rejectInFlight` is effectively unreachable live — but the seam models it
/// faithfully, so a future concurrent rewrite need only wrap the field in an
/// actor.
///
/// Two disjoint accountings:
///  - `inFlight`: ids observed but not yet completed. NEVER evicted (evicting an
///    in-flight entry would let its retry double-execute).
///  - `completed`: ids whose response is cached, ordered by completion `now`.
///    FIFO-evicted to `capacity`.
public struct MCPRequestDedupLedger {
    public let capacity: Int

    private struct CompletedEntry {
        let response: MCPDedupCachedResponse
        let completedAt: Date
    }

    private var inFlight: Set<MCPRequestKey>
    private var completed: [MCPRequestKey: CompletedEntry]

    public init(capacity: Int = 256) {
        self.capacity = capacity
        self.inFlight = []
        self.completed = [:]
    }

    /// Classify an observed request id and return the next ledger state.
    ///  - completed+cached → `.replayCached` (state unchanged);
    ///  - currently in-flight → `.rejectInFlight` (state unchanged);
    ///  - otherwise → `.proceed`, and the key is recorded as in-flight.
    public func observe(key: MCPRequestKey, now: Date) -> (DedupDecision, MCPRequestDedupLedger) {
        if let cached = completed[key] {
            return (.replayCached(response: cached.response), self)
        }
        if inFlight.contains(key) {
            return (.rejectInFlight, self)
        }
        var next = self
        next.inFlight.insert(key)
        return (.proceed, next)
    }

    /// Finish an in-flight request.
    ///  - `response != nil` → cache it as the final deterministic answer (a
    ///    successful result, or a tools/call `isError:true` result that replays
    ///    identically). Then FIFO-evict completed entries down to `capacity`.
    ///  - `response == nil` → RELEASE the slot for retry (a thrown/transient
    ///    handler must not cache a transient failure as the permanent answer).
    /// A `complete` for a key not in-flight is a harmless no-op (defensive).
    public func complete(key: MCPRequestKey, response: MCPDedupCachedResponse?, now: Date) -> MCPRequestDedupLedger {
        var next = self
        next.inFlight.remove(key)
        guard let response else {
            // Release: nothing cached, slot freed.
            return next
        }
        next.completed[key] = CompletedEntry(response: response, completedAt: now)
        next.evictIfNeeded()
        return next
    }

    /// FIFO eviction of COMPLETED entries by completion `now`, oldest first,
    /// until at capacity. In-flight entries live in a separate set and are never
    /// considered here, so a retry of an in-flight id is never silently dropped.
    private mutating func evictIfNeeded() {
        guard completed.count > capacity else {
            return
        }
        let ordered = completed.sorted { $0.value.completedAt < $1.value.completedAt }
        let overflow = completed.count - capacity
        for (key, _) in ordered.prefix(overflow) {
            completed.removeValue(forKey: key)
        }
    }
}
