import Foundation

/// What the boss decided to do about a session that's waiting on a human.
public enum BossDecisionKind: String, Codable, Sendable, CaseIterable {
    /// The boss would send (or did send) the proposed input to advance the
    /// session, because the friend's preferences cover this prompt.
    case autoAdvance
    /// The boss surfaced the prompt to the human and did not act (no clear
    /// preference, low confidence, or a destructive/secret prompt).
    case escalate
    /// The boss intentionally left the session waiting (e.g. nothing to do yet).
    case hold

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Unknown decodes to the safe, non-acting choice.
        self = BossDecisionKind(rawValue: raw) ?? .escalate
    }
}

/// Lifecycle of a recorded decision.
public enum BossDecisionStatus: String, Codable, Sendable {
    /// Logged as the boss's judgment, not executed (the audit dry-run that
    /// precedes turning auto-advance on).
    case recorded
    /// The proposed input was actually sent to the session.
    case applied
    /// The human corrected the boss after the fact.
    case overridden

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BossDecisionStatus(rawValue: raw) ?? .recorded
    }
}

/// One auditable record of a boss decision about a waiting session — the
/// centerpiece of the preference-driven inbox. It answers, for every call the
/// boss made: **what** (kind + proposedInput), **why** (preferenceCited +
/// confidence + reasoning), **for whom** (the resolved friend), **about what**
/// (the session + the waiting prompt), **when**, and **how it turned out**
/// (status). Durable and reviewable so the operator can audit and tune.
public struct BossInboxDecision: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var occurredAt: Date
    /// Who made the decision, e.g. `boss:slugger`.
    public var source: String
    public var entryId: UUID?
    public var sessionName: String?
    /// The friend whose preferences governed this decision (resolved at decision
    /// time), and their id — so an audit can be grouped/filtered by friend.
    public var friendName: String?
    public var friendId: String?
    /// The waiting prompt the boss was responding to (a bounded snippet).
    public var prompt: String
    public var kind: BossDecisionKind
    /// For `autoAdvance`, the input the boss would send / sent (e.g. `1`, `y`).
    public var proposedInput: String?
    /// The specific friend preference / note the boss relied on — the "why".
    public var preferenceCited: String?
    /// The boss's confidence the friend would want this (0...1), when given.
    public var confidence: Double?
    /// Freeform reasoning, for the human to read during audit / tuning.
    public var reasoning: String
    public var status: BossDecisionStatus

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        source: String,
        entryId: UUID? = nil,
        sessionName: String? = nil,
        friendName: String? = nil,
        friendId: String? = nil,
        prompt: String,
        kind: BossDecisionKind,
        proposedInput: String? = nil,
        preferenceCited: String? = nil,
        confidence: Double? = nil,
        reasoning: String,
        status: BossDecisionStatus = .recorded
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.source = source
        self.entryId = entryId
        self.sessionName = sessionName
        self.friendName = friendName
        self.friendId = friendId
        self.prompt = prompt
        self.kind = kind
        self.proposedInput = proposedInput
        self.preferenceCited = preferenceCited
        self.confidence = confidence
        self.reasoning = reasoning
        self.status = status
    }
}

public extension WorkspaceState {
    /// Newest-first cap for the decision log, matching the action log.
    static let decisionLogCap = 200

    /// Record a boss decision newest-first, trimming to the cap. Pure mutation
    /// (no persistence) so the model layer controls when to save — mirrors how
    /// the action log is appended.
    mutating func recordDecision(_ decision: BossInboxDecision) {
        decisionLog.insert(decision, at: 0)
        if decisionLog.count > Self.decisionLogCap {
            decisionLog.removeLast(decisionLog.count - Self.decisionLogCap)
        }
    }
}
