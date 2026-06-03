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

/// A decision as emitted by the boss in an `ouro-workbench-decisions` block,
/// before Workbench resolves the session and friend. `entry` is a process id or
/// unique session name; the app turns this into a full `BossInboxDecision`.
public struct BossInboxDecisionInput: Codable, Sendable {
    public var entry: String?
    public var kind: BossDecisionKind
    public var proposedInput: String?
    public var preferenceCited: String?
    public var confidence: Double?
    public var reasoning: String?
    /// The waiting prompt the boss is responding to, if it quotes it; the app
    /// falls back to the session's transcript tail when absent.
    public var prompt: String?

    public init(
        entry: String? = nil,
        kind: BossDecisionKind,
        proposedInput: String? = nil,
        preferenceCited: String? = nil,
        confidence: Double? = nil,
        reasoning: String? = nil,
        prompt: String? = nil
    ) {
        self.entry = entry
        self.kind = kind
        self.proposedInput = proposedInput
        self.preferenceCited = preferenceCited
        self.confidence = confidence
        self.reasoning = reasoning
        self.prompt = prompt
    }
}

/// Extracts boss decisions from a check-in reply, mirroring
/// `BossWorkbenchActionParser`: a fenced ```ouro-workbench-decisions``` JSON
/// array (or an `OURO_WORKBENCH_DECISIONS:` marker), decoded leniently so one
/// malformed decision never drops the rest of the batch.
public struct BossDecisionParser: Sendable {
    public init() {}

    public func parse(_ text: String) throws -> [BossInboxDecisionInput] {
        guard let json = fencedJSON(in: text) ?? markerJSON(in: text) else {
            return []
        }
        let wrappers = try JSONDecoder().decode([FailableDecodable<BossInboxDecisionInput>].self, from: Data(json.utf8))
        return wrappers.compactMap(\.base)
    }

    private func fencedJSON(in text: String) -> String? {
        let fence = "```ouro-workbench-decisions"
        guard let start = text.range(of: fence) else { return nil }
        let remainder = text[start.upperBound...]
        guard let end = remainder.range(of: "```") else { return nil }
        return String(remainder[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func markerJSON(in text: String) -> String? {
        let marker = "OURO_WORKBENCH_DECISIONS:"
        guard let start = text.range(of: marker) else { return nil }
        // Capture only the balanced JSON value after the marker, not everything
        // to EOF — otherwise trailing prose ("OURO_WORKBENCH_DECISIONS: [...] and
        // I'll check back later.") makes the whole payload invalid JSON and
        // silently drops the entire batch. Reuses the shared helper from
        // `BossWorkbenchAction.swift` (same fix applied to the action marker).
        return balancedJSONValue(in: text[start.upperBound...])
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

    /// Record a decision unless the most recent decision for the same session
    /// already has the same kind + prompt — so repeated Boss Watch ticks over a
    /// still-waiting prompt don't flood the log with duplicates. Returns whether
    /// it recorded.
    @discardableResult
    mutating func recordDecisionIfNew(_ decision: BossInboxDecision) -> Bool {
        guard isNewDecision(entryId: decision.entryId, prompt: decision.prompt, kind: decision.kind) else {
            return false
        }
        recordDecision(decision)
        return true
    }

    /// True when no recent decision for this session already matches the same
    /// prompt + kind. Used to gate execution *before* acting, so the boss never
    /// re-sends input for a prompt it already advanced (idempotency).
    func isNewDecision(entryId: UUID?, prompt: String, kind: BossDecisionKind) -> Bool {
        guard let recent = decisionLog.first(where: { $0.entryId == entryId }) else {
            return true
        }
        return !(recent.kind == kind && recent.prompt == prompt)
    }
}
