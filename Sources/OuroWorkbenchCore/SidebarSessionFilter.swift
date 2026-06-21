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

    /// U19(a): whether `query` contains at least one *structured* `owner:`/`status:`
    /// token — i.e. a token whose prefix is recognized AND which carries a non-empty
    /// value. A structured query searches GLOBALLY (across all workspaces) rather than
    /// only the current list scope, so the question the filter exists to answer
    /// ("what's waiting on me?") can't read as empty just because a blocked session
    /// lives in an unselected workspace.
    ///
    /// A bare `owner:` / `status:` (no value yet, still being typed) is *not* structured
    /// — it matches everything (see `matchesToken`), so flipping to a global scan on it
    /// would be surprising. A plain free-text query is not structured either; it stays
    /// scoped to the current workspace as before.
    public func isStructuredQuery(_ query: String) -> Bool {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .contains(where: Self.isStructuredToken)
    }

    /// A single token is structured when it has a recognized prefix AND a value after
    /// the colon. Mirrors the bare-prefix-is-neutral rule in `matchesToken`.
    private static func isStructuredToken(_ token: String) -> Bool {
        let lower = token.lowercased()
        for prefix in [ownerPrefix, statusPrefix] where lower.hasPrefix(prefix) {
            return !lower.dropFirst(prefix.count).isEmpty
        }
        return false
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

/// U19(b)/(c): seam-free copy for the sidebar filter's scope indicator and its zero-match
/// empty state. The view renders these verbatim; pinning them here keeps the wording
/// tested rather than buried as view literals.
public enum SidebarFilterPresentation {
    /// One-line scope indicator shown under the filter field so scoping is never silent:
    /// a structured query reads "Searching all workspaces"; a plain query reads
    /// "Searching <workspace>" (or a generic fallback when the workspace is unnamed).
    public static func scopeIndicator(isGlobal: Bool, workspaceName: String?) -> String {
        if isGlobal {
            return "Searching all workspaces"
        }
        let name = (workspaceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return "Searching this workspace"
        }
        return "Searching \(name)"
    }

    /// Title for the zero-match state — quotes the (trimmed) query so the operator sees
    /// exactly what was searched, distinct from a "no terminals yet" hint.
    public static func emptyStateTitle(query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return "No sessions match \"\(trimmed)\""
    }

    /// Description for the zero-match state. A global search that finds nothing is
    /// trustworthy ("searched every workspace"); a scoped one points at the rest of the
    /// workspace. Both name the one-click way out.
    public static func emptyStateDescription(isGlobal: Bool) -> String {
        if isGlobal {
            return "Searched every workspace and found nothing. Clear the filter to see all sessions."
        }
        return "Clear the filter to see all sessions in this workspace."
    }
}
