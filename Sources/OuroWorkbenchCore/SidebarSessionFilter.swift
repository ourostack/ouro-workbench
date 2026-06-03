import Foundation

/// Pure, testable predicate behind the sidebar's session-list filter (the
/// `TextField` at the top of `WorkbenchSidebarView`). Given a free-text query
/// and a session's salient fields, it decides whether the session stays
/// visible. This is the *persistent list filter* — distinct from the
/// in-terminal ⌘F search (`SwiftTerm.SearchOptions`, which scans the active
/// terminal's scrollback) and from the ⌘K command palette
/// (`WorkbenchCommandPalette`, a modal command launcher). It narrows which
/// rows the sidebar renders; it does not search inside a session.
///
/// Query grammar (whitespace-separated tokens, all ANDed, all case- and
/// diacritic-insensitive):
///
/// - A **plain** token (`recipes`) matches when it's a substring of the
///   session name OR the group name.
/// - `owner:human` matches only human-owned sessions; `owner:you` is an alias.
/// - `owner:agent` matches any agent-owned session (regardless of which agent).
/// - `owner:<name>` (e.g. `owner:slugger`) matches a session owned by that
///   agent — substring, so `owner:slug` matches `slugger`. `owner:human` /
///   `owner:agent` / `owner:you` are reserved and never treated as an agent
///   name.
/// - `status:<value>` matches the attention state. Accepts the raw state name
///   (`status:waitingOnHuman`) and friendlier aliases: `status:waiting`,
///   `status:active`, `status:idle`, `status:blocked`, `status:review`, and
///   `status:attention` (any state that needs the human — see
///   `AttentionState.needsHuman`).
///
/// An empty / whitespace-only query matches everything, so the filter is
/// invisible until the operator types — sidebar behavior is then exactly as
/// before.
public struct SidebarSessionFilter: Sendable {
    public init() {}

    /// Recognized prefixes for the structured tokens. Used both to parse a
    /// token and to keep the reserved `owner:` values from being mistaken for
    /// agent names.
    private static let ownerPrefix = "owner:"
    private static let statusPrefix = "status:"

    /// Decide whether a single session matches `query`.
    ///
    /// - Parameters:
    ///   - name: the session's display name.
    ///   - groupName: the name of the group/project the session lives in.
    ///   - owner: who owns the session (human vs. a named agent).
    ///   - attention: the session's current attention state.
    ///   - query: the raw text from the sidebar filter field.
    public func matches(
        name: String,
        groupName: String,
        owner: SessionOwner,
        attention: AttentionState,
        query: String
    ) -> Bool {
        let tokens = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else {
            return true
        }
        return tokens.allSatisfy { token in
            matchesToken(token, name: name, groupName: groupName, owner: owner, attention: attention)
        }
    }

    /// Convenience overload that pulls the fields off a `ProcessEntry`, given
    /// the entry's group name (which lives on `WorkbenchProject`, not the
    /// entry). Keeps the call site in the view model terse.
    public func matches(_ entry: ProcessEntry, groupName: String, query: String) -> Bool {
        matches(
            name: entry.name,
            groupName: groupName,
            owner: entry.owner,
            attention: entry.attention,
            query: query
        )
    }

    private func matchesToken(
        _ token: String,
        name: String,
        groupName: String,
        owner: SessionOwner,
        attention: AttentionState
    ) -> Bool {
        let lower = token.lowercased()
        if lower.hasPrefix(Self.ownerPrefix) {
            let value = String(lower.dropFirst(Self.ownerPrefix.count))
            // A bare `owner:` (nothing after the colon yet) is neutral — it
            // matches everything so a half-typed token doesn't blank the list
            // while the operator is still typing the value.
            guard !value.isEmpty else {
                return true
            }
            return matchesOwner(value, owner: owner)
        }
        if lower.hasPrefix(Self.statusPrefix) {
            let value = String(lower.dropFirst(Self.statusPrefix.count))
            guard !value.isEmpty else {
                return true
            }
            return matchesStatus(value, attention: attention)
        }
        return containsSubstring(token, in: [name, groupName])
    }

    /// `value` is already lowercased.
    private func matchesOwner(_ value: String, owner: SessionOwner) -> Bool {
        switch value {
        case "human", "you", "me":
            return owner == .human
        case "agent":
            return owner.agentName != nil
        default:
            // Treat as an agent-name substring. Human-owned sessions never
            // match a name query.
            guard let agentName = owner.agentName else {
                return false
            }
            return agentName.range(of: value, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// `value` is already lowercased.
    private func matchesStatus(_ value: String, attention: AttentionState) -> Bool {
        switch value {
        case "idle":
            return attention == .idle
        case "active", "running":
            return attention == .active
        case "waiting", "waitingonhuman", "human":
            return attention == .waitingOnHuman
        case "blocked":
            return attention == .blocked
        case "review", "needsbossreview", "boss":
            return attention == .needsBossReview
        case "attention", "needshuman":
            // Anything that wants the operator: waiting, blocked, or flagged
            // for boss review (see AttentionState.needsHuman).
            return attention.needsHuman
        default:
            // Fall back to a substring match on the raw state name so an
            // unrecognized status token (e.g. a state added later) still does
            // something sensible rather than hiding every row.
            return attention.rawValue.range(of: value, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private func containsSubstring(_ token: String, in fields: [String]) -> Bool {
        fields.contains { field in
            field.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
