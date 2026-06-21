import Foundation

/// The lifecycle state of a queued `workbench_request_action`, read back by
/// requestId (#U24). Mirrors `workbench_proposal_result`'s not-ready/ready shape:
/// a request the app hasn't drained yet is `queued` (a clean not-ready poll,
/// never an error), and once the app drains + applies it the action-log entry
/// stamped with that requestId resolves it to `applied` or `failed`.
public enum WorkbenchActionResultState: String, Codable, Equatable, Sendable {
    /// The request is still in the queue (pending or in-flight in `processing/`)
    /// — the app hasn't applied it yet. The boss polls again; never an error.
    case queued
    /// The app applied the request and it succeeded.
    case applied
    /// The app applied the request and it failed (skipped / errored).
    case failed
    /// No request with this id is queued and no action-log entry carries it —
    /// either the id is wrong, or its log entry rolled off the bounded log.
    case unknown
}

/// The boss-facing `workbench_action_result` readback (#U24): the lifecycle
/// `state` of one requestId plus, once resolved, the human-readable `result`
/// text and `succeeded` flag the app recorded — so the boss can say "request X
/// applied" with evidence instead of "I think it worked", and the operator's
/// audit log shares the requestId key with the boss's queued request.
public struct WorkbenchActionResultReadback: Codable, Equatable, Sendable {
    public var requestId: String
    public var state: WorkbenchActionResultState
    /// The action-log result text, once the request resolved. Omitted (nil) while
    /// `queued` or when `unknown`.
    public var result: String?
    /// Whether the resolved action succeeded. Omitted while `queued`/`unknown`.
    public var succeeded: Bool?

    public init(
        requestId: String,
        state: WorkbenchActionResultState,
        result: String? = nil,
        succeeded: Bool? = nil
    ) {
        self.requestId = requestId
        self.state = state
        self.result = result
        self.succeeded = succeeded
    }
}

/// Pure derivation of a `WorkbenchActionResultReadback` from the two durable
/// sources the boss's request flows through (#U24): whether the queue still
/// holds the request (pending or `processing/`), and the action log the app
/// writes after it drains + applies. No I/O — the MCP server checks the queue
/// and loads the action log, then hands both signals here, so the classifier is
/// unit-tested in Core and reused by the read-only `workbench_action_result`
/// tool.
///
/// Precedence: a request still in the queue reads `queued` (not-ready) even if a
/// stale log entry with the same id somehow exists — the queue is the live
/// truth that the app hasn't finished. Otherwise the action-log entry stamped
/// with the requestId resolves it to `applied`/`failed`. Neither present →
/// `unknown` (wrong id, or the entry rolled off the bounded log).
public struct WorkbenchActionResultClassifier {
    public init() {}

    public func readback(
        requestId: String,
        stillQueued: Bool,
        logEntry: WorkbenchActionLogEntry?
    ) -> WorkbenchActionResultReadback {
        if stillQueued {
            return WorkbenchActionResultReadback(requestId: requestId, state: .queued)
        }
        guard let logEntry else {
            return WorkbenchActionResultReadback(requestId: requestId, state: .unknown)
        }
        return WorkbenchActionResultReadback(
            requestId: requestId,
            state: logEntry.succeeded ? .applied : .failed,
            result: logEntry.result,
            succeeded: logEntry.succeeded
        )
    }
}
