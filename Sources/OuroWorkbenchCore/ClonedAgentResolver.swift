import Foundation

/// A minimal projection of an `OuroAgentRecord` the App injects into `ClonedAgentResolver` after a
/// clone. It carries ONLY what the resolution needs — the bundle name, whether its `agent.json` is
/// present (the roster scan reports `.missingConfig` when the dir exists but `agent.json` doesn't),
/// and the outward-lane provider string. Keeping this a value (not the App's record) keeps the
/// resolver pure and fully unit-testable with no I/O.
public struct ClonedRosterEntry: Equatable, Sendable {
    public let name: String
    /// True iff the bundle's `agent.json` exists on disk (roster status != `.missingConfig`).
    public let agentJsonPresent: Bool
    /// The outward (`humanFacing`) lane's `--provider` flag value, or `nil` when the lane is
    /// unconfigured / the bundle is invalid.
    public let provider: String?

    public init(name: String, agentJsonPresent: Bool, provider: String?) {
        self.name = name
        self.agentJsonPresent = agentJsonPresent
        self.provider = provider
    }
}

/// The resolution of "which agent did this clone produce, and is its bundle present?".
public struct ClonedAgentResolution: Equatable, Sendable {
    /// The resolved agent name — the operator-given name (trimmed) when non-blank, the derived
    /// remote label when blank, OR (when a divergent name surfaces via the roster diff) the actual
    /// roster name that landed.
    public let name: String
    /// Whether the resolved agent's `agent.json` is present in the refreshed roster.
    public let agentJsonPresent: Bool
    /// The resolved agent's outward-lane provider flag value, or `nil`.
    public let provider: String?

    public init(name: String, agentJsonPresent: Bool, provider: String?) {
        self.name = name
        self.agentJsonPresent = agentJsonPresent
        self.provider = provider
    }
}

/// F7 cold-review CRITICAL fix — resolve the agent a headless clone ACTUALLY produced from the
/// REFRESHED roster (the filesystem `agent.json` scan `refreshOuroAgents()` rebuilds), rather than
/// assuming Workbench's name derivation matches `ouro`'s.
///
/// The bug this fixes: `cloneAgentHeadless` gated the entire bundle/probe inspection on
/// `!resolvedName.isEmpty`. But the agent-name field is OPTIONAL and the RECOMMENDED DEFAULT is to
/// leave it BLANK (the clone derives a name from the repo). With a blank name the inspection was
/// SKIPPED → `agentJsonPresent` stayed false → a clean SUCCESSFUL clone on the default path was
/// reported as the false `.invalidMissingAgentJson` failure ("its configuration is missing").
///
/// PURE: no I/O. The App snapshots the roster names BEFORE the clone, calls `refreshOuroAgents()`
/// (synchronous) AFTER, projects the refreshed records into `ClonedRosterEntry` values, and feeds
/// both snapshots here. BOTH the named and the blank paths go through this ONE resolution — the
/// roster (which IS the on-disk `agent.json` scan) is the consistent source of presence for both.
public enum ClonedAgentResolver {
    /// - `givenName`: the operator-typed agent name (may be blank — the recommended default).
    /// - `remote`: the clone remote (used to DERIVE the expected name when `givenName` is blank).
    /// - `rosterNamesBefore`: agent names present BEFORE the clone (the diff baseline).
    /// - `rosterAfter`: the refreshed roster projection AFTER the clone.
    ///
    /// Resolution:
    /// (a) `givenName` non-blank → expected name = the trimmed given name;
    /// (b) else → expected name = `CloneAgentFlowState.remoteLabel(forRemote:)` (strips `.git`/`.ouro`);
    /// (c) confirm by looking the expected name up in `rosterAfter` (case-insensitive). If found →
    ///     present from THAT entry (honoring its own `agentJsonPresent`), provider from its lane,
    ///     resolved name = the roster's canonical casing.
    /// (d) if NOT found by name → fall back to the roster DIFF (`rosterAfter` names minus
    ///     `rosterNamesBefore`, case-insensitive). If EXACTLY ONE new entry → that IS the clone
    ///     (covers `ouro`'s naming diverging from `remoteLabel`); resolve to it.
    /// (e) otherwise (zero new, or an AMBIGUOUS multi-new diff) → honest `agentJsonPresent=false`,
    ///     provider nil, name = the expected (derived/given) name.
    public static func resolveClonedAgent(
        givenName: String,
        remote: String,
        rosterNamesBefore: [String],
        rosterAfter: [ClonedRosterEntry]
    ) -> ClonedAgentResolution {
        let trimmedGiven = givenName.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedName = trimmedGiven.isEmpty
            ? CloneAgentFlowState.remoteLabel(forRemote: remote)
            : trimmedGiven

        // (c) The expected name is the authority when it's actually in the roster — this covers the
        // common case (named clone, and the blank-name clone whose derived name `ouro` agreed on).
        if let match = rosterAfter.first(where: {
            $0.name.caseInsensitiveCompare(expectedName) == .orderedSame
        }) {
            return ClonedAgentResolution(
                name: match.name,
                agentJsonPresent: match.agentJsonPresent,
                provider: match.provider
            )
        }

        // (d) The expected name isn't in the roster — the derivation may have diverged from `ouro`'s
        // naming. If the clone added EXACTLY ONE new entry vs the before-snapshot, that's the clone.
        let beforeNames = Set(rosterNamesBefore.map { $0.lowercased() })
        let newEntries = rosterAfter.filter { !beforeNames.contains($0.name.lowercased()) }
        if newEntries.count == 1, let sole = newEntries.first {
            return ClonedAgentResolution(
                name: sole.name,
                agentJsonPresent: sole.agentJsonPresent,
                provider: sole.provider
            )
        }

        // (e) Nothing created, or an ambiguous multi-new diff we won't guess: honest not-present.
        return ClonedAgentResolution(
            name: expectedName,
            agentJsonPresent: false,
            provider: nil
        )
    }
}
