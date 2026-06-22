import Foundation

/// F11a Defect 1 — the pure decision seam for reaping leaked persistent
/// `screen` sessions.
///
/// `archiveCustomSession` / `deleteCustomSession` only ever guarded
/// `activeSessions[id] == nil` and then mutated state — they never quit the
/// `ouro-wb-<id>` screen. A session that detached-but-stayed-alive (after
/// `markTerminated` cleared `activeSessions` without quitting), or that survived
/// an app crash, leaks the screen and its child process forever. This seam
/// decides, from a snapshot of live session names and the set of *known* entry
/// ids, which live sessions have no owning entry (orphans to quit).
///
/// Derivation is FORWARD only: hash each known id to its session name and
/// subtract that set from the live names. A live session is spared ONLY if some
/// known id hashes to it. We never parse a uuid back out of a name (the
/// `sessionName(for:)` transform is lossy — it strips dashes/lowercases), so a
/// reverse parse could mis-spare or mis-kill. Forward derivation makes the
/// no-kill guarantee structural: any name a known id produces is, by
/// construction, in the spare set.
public enum ScreenSessionReaper: Sendable {
    /// The live `screen` session names that no known workbench entry owns — the
    /// orphans safe to quit. `liveSessionNames` minus the forward hash of every
    /// known entry id.
    public static func orphanedSessionNames(
        liveSessionNames: Set<String>,
        knownEntryIds: Set<UUID>
    ) -> Set<String> {
        let ownedNames = Set(knownEntryIds.map(PersistentTerminalSession.sessionName(for:)))
        return liveSessionNames.subtracting(ownedNames)
    }
}
