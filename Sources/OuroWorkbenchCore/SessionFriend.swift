import Foundation

/// Who a session belongs to — a `human` or an `agent`. Mirrors the Ouro
/// `FriendRecord.kind` so a Workbench session can be tied to a real friend the
/// boss already knows.
public enum SessionFriendKind: String, Codable, Sendable, CaseIterable {
    case human
    case agent

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionFriendKind(rawValue: raw) ?? .human
    }
}

/// Relationship trust for a friend, mirroring the Ouro `TrustLevel`
/// (`family` / `friend` / `acquaintance` / `stranger`). `family` and `friend`
/// are the trusted levels — the only ones eligible for boss auto-advance.
public enum SessionFriendTrust: String, Codable, Sendable, CaseIterable {
    case family
    case friend
    case acquaintance
    case stranger

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Unknown decodes to the most cautious level rather than a trusted one.
        self = SessionFriendTrust(rawValue: raw) ?? .stranger
    }

    /// Whether this level is trusted (eligible, in combination with the
    /// session's own trust, for the boss to act). Matches Ouro's TRUSTED_LEVELS.
    public var isTrusted: Bool {
        self == .family || self == .friend
    }
}

/// The friend a Workbench session acts for / as. Carries enough identity for
/// the boss to look up the matching `FriendRecord` (by `id` when known, else by
/// `name`) and apply that friend's preferences. This is identity only — no
/// policy lives here; the boss owns the preference judgment.
public struct SessionFriend: Codable, Equatable, Sendable, Identifiable {
    /// Stable identifier. The Ouro `FriendRecord` UUID when reconciled with the
    /// boss; otherwise a name slug so a freeform-assigned friend still has a
    /// stable key.
    public var id: String
    public var name: String
    public var kind: SessionFriendKind
    public var trust: SessionFriendTrust

    public init(id: String, name: String, kind: SessionFriendKind = .human, trust: SessionFriendTrust = .friend) {
        self.id = id
        self.name = name
        self.kind = kind
        self.trust = trust
    }

    /// Build a friend from a freeform name (no known `FriendRecord` id yet),
    /// deriving a stable slug id from the name.
    public init(name: String, kind: SessionFriendKind = .human, trust: SessionFriendTrust = .friend) {
        self.init(id: Self.slug(from: name), name: name, kind: kind, trust: trust)
    }

    /// Compact label for chips / prompts, e.g. `Ari (human, family)`.
    public var displayLabel: String {
        "\(name) (\(kind.rawValue), \(trust.rawValue))"
    }

    /// Lowercase, hyphenated slug of a name — a stable provisional id until the
    /// boss reconciles it with a real `FriendRecord`.
    public static func slug(from name: String) -> String {
        let lowered = name.lowercased()
        var slug = ""
        var lastWasHyphen = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                slug.append("-")
                lastWasHyphen = true
            }
        }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

public extension WorkspaceState {
    /// The friend governing a session: its own assigned friend if set, otherwise
    /// its group's `defaultFriend`, otherwise nil (unassigned — the boss never
    /// auto-advances an unassigned session).
    func effectiveFriend(for entry: ProcessEntry) -> SessionFriend? {
        if let friend = entry.friend {
            return friend
        }
        return projects.first { $0.id == entry.projectId }?.defaultFriend
    }
}
