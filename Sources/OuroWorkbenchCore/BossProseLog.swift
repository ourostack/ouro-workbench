import Foundation

/// One persisted entry of boss prose — the human-readable answer the boss gave on a
/// check-in (#F12a gap 3a). `bossCheckInAnswer` is a transient @Published string the
/// next tick overwrites, so the operator's record of what the boss SAID was lost.
/// This is the durable, bounded history that survives across ticks and restarts.
public struct BossProseEntry: Codable, Equatable, Identifiable, Sendable {
    /// Hard cap on a single entry's text so a verbose boss reply can't bloat the
    /// saved workspace state. Applied at construction.
    public static let textCap = 4000

    public var id: UUID
    public var occurredAt: Date
    /// Who produced the prose, e.g. `boss:slugger`.
    public var source: String
    /// The boss's answer, capped at `textCap`.
    public var text: String

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        source: String,
        text: String
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.source = source
        self.text = String(text.prefix(Self.textCap))
    }
}

public extension WorkspaceState {
    /// Newest-first cap on retained boss-prose entries. Bounded like the action /
    /// decision logs so the persisted state stays small.
    static let proseLogCap = 50

    /// Record a boss-prose entry newest-first, trimming to the cap. Pure mutation
    /// (no persistence) so the model layer controls when to save — mirrors how the
    /// action / decision logs are appended.
    mutating func recordProse(_ entry: BossProseEntry) {
        proseLog.insert(entry, at: 0)
        if proseLog.count > Self.proseLogCap {
            proseLog.removeLast(proseLog.count - Self.proseLogCap)
        }
    }
}
