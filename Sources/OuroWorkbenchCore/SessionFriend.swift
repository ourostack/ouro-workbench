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

public extension SessionFriend {
    /// The machine's owner as a friend, mirroring how the Ouro CLI resolves a
    /// local session (`provider: "local"`, `externalId: <os username>`): a
    /// machine maps to one human, family-trust by default. The `id` is the
    /// username — the exact external id the boss resolves `(local, username)`
    /// against — so the real `FriendRecord` (and its preferences) attaches
    /// without separate reconciliation. Returns nil when no OS user is resolvable.
    ///
    /// Impure (reads the OS); call it at the app/MCP boundary and inject the
    /// result into `effectiveFriend(for:fallback:)`, keeping resolution pure.
    static func machineOwner(
        username: String = NSUserName(),
        fullName: String = NSFullUserName()
    ) -> SessionFriend? {
        let user = username.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else { return nil }
        let trimmedFull = fullName.trimmingCharacters(in: .whitespaces)
        let name = trimmedFull.isEmpty ? user : trimmedFull
        return SessionFriend(id: user, name: name, kind: .human, trust: .family)
    }

    /// Boundary resolver for app/MCP surfaces that want the machine owner but
    /// must keep XCTest rendering hermetic. `NSFullUserName()` can wake
    /// Contacts/CoreData/XPC on macOS; under XCTest we use the short username
    /// unless a live lookup is explicitly requested.
    static func resolvedMachineOwner(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        username: () -> String = NSUserName,
        fullName: () -> String = NSFullUserName,
        classLookup: (String) -> AnyClass? = NSClassFromString
    ) -> SessionFriend? {
        let user = username().trimmingCharacters(in: .whitespaces)
        if isRunningUnderXCTest(environment: environment, classLookup: classLookup),
           environment["OURO_WORKBENCH_LIVE_OWNER_NAME"] != "1" {
            return machineOwner(username: user, fullName: "")
        }
        return machineOwner(username: user, fullName: fullName())
    }

    /// Display name companion for `resolvedMachineOwner(...)`.
    static func resolvedMachineOwnerName(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        username: () -> String = NSUserName,
        fullName: () -> String = NSFullUserName,
        classLookup: (String) -> AnyClass? = NSClassFromString
    ) -> String {
        let user = username().trimmingCharacters(in: .whitespaces)
        let fallback = user.isEmpty ? "the operator" : user
        return resolvedMachineOwner(
            environment: environment,
            username: { user },
            fullName: fullName,
            classLookup: classLookup
        )?.name ?? fallback
    }

    private static func isRunningUnderXCTest(
        environment: [String: String],
        classLookup: (String) -> AnyClass?
    ) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        if classLookup("XCTestCase") != nil || classLookup("XCTest.XCTestCase") != nil {
            return true
        }
        return false
    }
}

public extension WorkspaceState {
    /// The friend governing a session: its own assigned friend if set, otherwise
    /// its group's `defaultFriend`, otherwise the injected `fallback` (the
    /// machine owner, resolved at the boundary). Stays pure: live OS reads stay in
    /// `SessionFriend.resolvedMachineOwner()`, not here, so resolution is testable.
    /// A nil result (no assignment, no default, no fallback) means unassigned,
    /// which the boss never auto-advances.
    func effectiveFriend(for entry: ProcessEntry, fallback: SessionFriend? = nil) -> SessionFriend? {
        if let friend = entry.friend {
            return friend
        }
        if let groupDefault = projects.first(where: { $0.id == entry.projectId })?.defaultFriend {
            return groupDefault
        }
        return fallback
    }
}
