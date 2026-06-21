import Foundation

/// Maps each `TerminalCommandPlanKind` to ONE plain operator-facing sentence
/// (U40).
///
/// `markStarted` used to copy the plan's raw `reason` straight into the entry's
/// operator-visible `lastSummary` (and from there into the boss prompt) — so a
/// just-launched session read "respawn X from persisted workbench context" or
/// "prepare X command for manual review", mildly-technical jargon in a status
/// line. This phrasebook is the single place the kind → sentence vocabulary lives,
/// keyed off the typed `kind` alone so it can never leak the internal string,
/// while the raw `reason` stays available for logs / disclosure — the same shape
/// `RecoveryReasonPhrasebook` established for `RecoveryAction`.
public struct TerminalCommandPlanPhrasebook: Sendable {
    public init() {}

    /// One plain sentence describing what just happened for this plan, naming the
    /// entry. Keyed off the `kind` alone (never the raw `reason`), so the internal
    /// planner string can't surface in the session status line or the boss prompt.
    public func operatorSentence(for kind: TerminalCommandPlanKind, entryName: String) -> String {
        switch kind {
        case .launch:
            return "Started \(entryName)."
        case .reattach:
            return "Reconnected to \(entryName)."
        case .resume:
            return "Resumed \(entryName)."
        case .respawn:
            return "Reopened \(entryName) from its last checkpoint."
        case .manualReview:
            return "Opened \(entryName) for you to review."
        }
    }
}
