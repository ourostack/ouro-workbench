import Foundation

/// Maps each `RecoveryAction` to ONE plain operator-facing sentence (U8c / U7).
///
/// The planner emits a precise but internal `reason` string for every plan
/// ("trusted non-agent process may be respawned by policy", "lacks a persisted
/// session id", "session still running — reconnect the terminal"). Shown
/// verbatim those read as debug jargon on the Recovery sheet, the inactive
/// surface, and the drill rows. This phrasebook is the single place the
/// action → sentence vocabulary lives so every surface agrees, while the raw
/// reason stays available for an on-demand tooltip / disclosure for power users.
public struct RecoveryReasonPhrasebook: Sendable {
    public init() {}

    /// One plain sentence describing what activating recovery does for this
    /// action. Deliberately ignores the raw `rawReason` for its phrasing —
    /// the sentence is keyed off the action alone so it can never leak the
    /// internal string — but takes it as a parameter to keep call sites honest
    /// about where the raw reason came from (and to allow future
    /// action-specific nuance without changing callers).
    public func operatorSentence(for action: RecoveryAction, rawReason: String) -> String {
        switch action {
        case .reattach:
            return "Still running — reconnecting loses nothing."
        case .autoResume:
            return "Resumes its last conversation automatically."
        case .respawn:
            return "Reopens from its saved checkpoint."
        case .manualActionNeeded:
            return "No resumable session — needs you to start it fresh."
        case .noAction:
            return "Nothing to recover."
        }
    }

    /// The exact planner reason, preserved verbatim for the on-demand
    /// disclosure / tooltip. Kept as a named seam so a caller never reaches for
    /// the raw `RecoveryPlan.reason` directly when it means "the auditable
    /// detail behind the plain sentence."
    public func rawReasonForDisclosure(_ rawReason: String) -> String {
        rawReason
    }
}
