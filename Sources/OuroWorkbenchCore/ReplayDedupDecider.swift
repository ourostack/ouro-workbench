import Foundation

/// F11b Defect 3 — the pure decision seam for replay double-execute prevention.
///
/// The action queue is correctly at-least-once: `drain()` moves request files
/// from pending → `processing/`, `confirmApplied(id)` deletes the `processing/`
/// file AFTER the App applies the request, and `recoverUnconfirmed()` replays
/// anything still in `processing/` on the next launch. The hazard lives in the
/// App apply path: it runs the side effect (the `applyBossAction` for the
/// request) SYNCHRONOUSLY, then confirms OFF-MAIN in a detached task — so a
/// crash in that window leaves the `processing/` file, and recovery replays an
/// ALREADY-APPLIED request. Before F11b the only `.sendInput` replay guard was
/// `isNewDecision(entryId:prompt:livePrompt)`, keyed on the LIVE transcript tail
/// at apply time; after a crash+replay the session has advanced, so the prompt
/// differs and the keystroke is sent a SECOND time. `.createSession` /
/// `.createTerminal` / `.createGroup` had NO replay dedup at all.
///
/// This seam is the universal guard. It decides, from the durable set of applied
/// request ids (the `applied/` marker-dir ledger that `WorkbenchActionRequestQueue`
/// maintains), whether a request the App is about to apply has already been
/// applied — keyed STRICTLY on the request id, which already keys the
/// `processing/` filename.
///
/// Id-keyed, NOT fingerprint-keyed (the false-skip boundary): a boss may
/// DELIBERATELY re-issue the same effect with a NEW request id — that's a fresh
/// id → correctly `.apply`. Only an identical-id REPLAY (the same request file
/// recovered from `processing/` after a crash) is skipped. Fingerprint dedup
/// stays at ENQUEUE only (pending + processing); the applied ledger is id-keyed
/// alone, so it can never false-skip a deliberate repeat.
public struct ReplayDedupDecider: Sendable {
    public init() {}

    /// Whether the request identified by `requestId` should be applied or skipped
    /// as an already-applied replay. `.skipAlreadyApplied` iff `appliedRequestIds`
    /// already contains the id; otherwise `.apply`.
    public func decide(requestId: UUID, appliedRequestIds: Set<UUID>) -> ReplayDecision {
        appliedRequestIds.contains(requestId) ? .skipAlreadyApplied : .apply
    }
}

/// The outcome of a replay-dedup decision (see `ReplayDedupDecider`).
public enum ReplayDecision: Equatable, Sendable {
    /// The request has not been applied before — apply it.
    case apply
    /// The request id is already in the applied ledger — skip it as a replay of
    /// an already-applied request (a crash-recovered `processing/` file).
    case skipAlreadyApplied
}
