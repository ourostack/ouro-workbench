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
    /// The app APPLIED the request (the durable F11b `applied/` ledger marker is
    /// present) but no action-log entry carries it — the post-apply `save()` threw
    /// after the side effect ran, so the outcome text was lost. The action RAN
    /// (succeeded:true); only its detailed outcome is unavailable. A DISTINCT state
    /// from `.applied` so the boss is never told a confirmed outcome the workbench
    /// never persisted — degraded-mode honesty (#F12a gap 1).
    case appliedUnconfirmed
    /// No request with this id is queued, no action-log entry carries it, and it
    /// isn't in the applied ledger — either the id is wrong, or its log entry
    /// rolled off the bounded log.
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
/// Precedence (highest → lowest):
///  1. `stillQueued` → `queued` (not-ready) even if a stale log entry or applied
///     marker with the same id exists — the queue is the live truth that the app
///     hasn't finished.
///  2. the action-log entry stamped with the requestId resolves it to
///     `applied`/`failed` (the resolved, persisted truth).
///  3. `isApplied` (the durable F11b `applied/` ledger marker) with NO log entry →
///     `appliedUnconfirmed`: the side effect ran but the post-apply `save()` threw,
///     so the outcome text was lost. Honest "ran; outcome unavailable" rather than
///     the lie `unknown` (#F12a gap 1). Reachable only in the save-fail window —
///     the steady-state sweep clears the marker once `processing/` is gone.
///  4. none of the above → `unknown` (wrong id, or the entry rolled off the log).
public struct WorkbenchActionResultClassifier {
    /// The honest outcome text for an action that ran but whose detailed outcome
    /// wasn't persisted (the post-apply `save()` threw). Single source of truth so
    /// the App can't drift the copy.
    public static let appliedUnconfirmedResult =
        "Applied; detailed outcome unavailable (state save failed)."

    public init() {}

    public func readback(
        requestId: String,
        stillQueued: Bool,
        isApplied: Bool,
        logEntry: WorkbenchActionLogEntry?
    ) -> WorkbenchActionResultReadback {
        if stillQueued {
            return WorkbenchActionResultReadback(requestId: requestId, state: .queued)
        }
        if let logEntry {
            return WorkbenchActionResultReadback(
                requestId: requestId,
                state: logEntry.succeeded ? .applied : .failed,
                result: logEntry.result,
                succeeded: logEntry.succeeded
            )
        }
        if isApplied {
            return WorkbenchActionResultReadback(
                requestId: requestId,
                state: .appliedUnconfirmed,
                result: Self.appliedUnconfirmedResult,
                succeeded: true
            )
        }
        return WorkbenchActionResultReadback(requestId: requestId, state: .unknown)
    }
}
