import Foundation

/// Finds waiting-on-human sessions that have fallen out of triage (#F12a gap 3b).
///
/// Boss decisions reach the operator's inbox via `decisionLog` → `openInbox`. But if
/// the boss emits NO decisions block — or a decision whose `entryId` couldn't be
/// resolved (`processEntry(matching:)` returned nil) — a session that's genuinely
/// waiting on a human never enters the inbox and silently falls out of triage. There
/// was no reconciliation pass to catch it.
///
/// This pure seam returns the ids of active waiting sessions NOT already covered by
/// an open inbox decision, so the App can synthesize an `.escalate` decision per id
/// (deduped via `recordDecisionIfNew`, so a still-waiting session isn't re-escalated
/// every tick).
public enum WaitingSessionReconciler: Sendable {
    /// The ids of non-archived `.waitingOnHuman` sessions whose entry id is NOT in
    /// the open inbox (i.e. no open decision already triages them). A decision with
    /// a nil `entryId` covers nothing (it can't be attributed to a session), so a
    /// waiting session it doesn't name is still returned.
    public static func untriagedWaitingEntryIds(
        entries: [ProcessEntry],
        openInbox: [BossInboxDecision]
    ) -> [UUID] {
        let covered = Set(openInbox.compactMap(\.entryId))
        return entries
            .filter { !$0.isArchived && $0.attention == .waitingOnHuman && !covered.contains($0.id) }
            .map(\.id)
    }
}
