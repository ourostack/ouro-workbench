import Foundation

/// Resolves which installed agent should become the machine boss when the
/// persisted selection is UNRESOLVED. The boss is never hardcoded; on a fresh or
/// factory-reset machine it is chosen from the installed-agent inventory,
/// count-based:
///   - 0 usable agents  → nil (onboarding routes to create/restore an agent)
///   - exactly 1 usable → adopt it automatically
///   - more than 1      → nil (the human picks; Workbench never guesses)
///
/// This replaces the former hardcoded `"slugger"` default, which landed first-run
/// on a non-existent agent on every machine without an agent by that name.
public enum BossAutoResolution {
    /// The agent name to auto-adopt as boss, or nil when a human choice is needed
    /// (>1 usable), none is usable, or the persisted boss already resolves to an
    /// installed bundle (never silently switch away from a real selection).
    public static func adoptableBossName(
        persistedBossName: String,
        agents: [OuroAgentRecord]
    ) -> String? {
        let trimmed = persistedBossName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvesToInstalled = agents.contains {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        // Only resolve when the persisted boss is unresolved — empty, or naming no
        // installed bundle. A boss that resolves to an installed bundle (even an
        // unusable/disabled one) is left alone for the repair/choose path; we must
        // never silently switch away from a deliberate selection.
        guard trimmed.isEmpty || !resolvesToInstalled else { return nil }
        let usable = agents.filter(\.isUsableAsBoss)
        guard usable.count == 1 else { return nil }
        return usable[0].name
    }
}
