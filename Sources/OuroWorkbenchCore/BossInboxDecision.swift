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

/// Where a decision sits in the operator's **human triage** flow — orthogonal to
/// `BossDecisionStatus` (the boss-side lifecycle). `nil` triage = open / untriaged
/// (the default, and what every pre-triage persisted decision decodes to). A
/// decision the boss *escalated* starts open and stays in the inbox until the
/// operator acts on it.
public enum DecisionTriage: Codable, Equatable, Sendable {
    /// The operator has seen it and acknowledges it, but isn't acting yet. Kept
    /// out of the open queue (the operator chose to park it).
    case acknowledged(at: Date)
    /// Hidden from the open queue until `until`; it resurfaces once `now` passes
    /// that instant (e.g. "remind me in 1h" / "until I'm done").
    case snoozed(until: Date)
    /// Dealt with — permanently out of the open queue.
    case resolved(at: Date)

    /// Whether a decision in this triage state should still appear in the open
    /// inbox at `now`: an elapsed snooze qualifies; acknowledged, resolved, and a
    /// still-active snooze do not. (Open / `nil` triage is handled by the caller.)
    /// One definition shared by the openInbox filter and any UI badge.
    public func isOpen(at now: Date) -> Bool {
        switch self {
        case .acknowledged, .resolved:
            return false
        case let .snoozed(until):
            // A snooze that has elapsed resurfaces as open.
            return until <= now
        }
    }

    private enum CodingKeys: String, CodingKey { case state, at, until }
    private enum State: String, Codable { case acknowledged, snoozed, resolved }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown / corrupt state decodes to `.resolved(at: .distantPast)` — the
        // safe non-queue choice — rather than throwing and dropping the whole
        // decision row via the lenient array decoder. (An open item needs no
        // recovery: the field is simply absent, which Swift maps to `nil`.)
        guard let state = try? c.decode(State.self, forKey: .state) else {
            self = .resolved(at: .distantPast)
            return
        }
        switch state {
        case .acknowledged:
            self = .acknowledged(at: try c.decodeIfPresent(Date.self, forKey: .at) ?? Date())
        case .snoozed:
            self = .snoozed(until: try c.decodeIfPresent(Date.self, forKey: .until) ?? Date())
        case .resolved:
            self = .resolved(at: try c.decodeIfPresent(Date.self, forKey: .at) ?? Date())
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .acknowledged(at):
            try c.encode(State.acknowledged, forKey: .state)
            try c.encode(at, forKey: .at)
        case let .snoozed(until):
            try c.encode(State.snoozed, forKey: .state)
            try c.encode(until, forKey: .until)
        case let .resolved(at):
            try c.encode(State.resolved, forKey: .state)
            try c.encode(at, forKey: .at)
        }
    }
}

/// Priority tier for an open inbox item — a small, fixed set (anti-alarm-fatigue:
/// ≤4 tiers). Derived from the decision `kind` plus the `PromptSafetyClassifier`
/// read of the prompt, so a destructive/secret escalation sorts above a plain
/// one. Higher `rawValue` sorts first.
public enum DecisionSeverity: Int, Codable, Sendable, CaseIterable, Comparable {
    /// Hold / informational — the boss is parked, nothing pressing.
    case low = 0
    /// A routine attention item with no destructive/secret signal — e.g. a
    /// blocked auto-advance that fell back to the human.
    case normal = 1
    /// An escalation the boss surfaced because it genuinely needs the human.
    case elevated = 2
    /// The prompt is destructive/irreversible or touches secrets — top of queue,
    /// always shown first.
    case critical = 3

    public static func < (lhs: DecisionSeverity, rhs: DecisionSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Short human label for the severity accent / grouping header.
    public var label: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .elevated: return "Needs you"
        case .critical: return "Critical"
        }
    }

    /// Severity for a decision: a destructive/secret prompt is always `critical`
    /// (the `PromptSafetyClassifier` floor — the same one the auto-advance gate
    /// uses), regardless of kind; otherwise it follows the kind — `escalate` →
    /// `elevated`, `autoAdvance` (when it still surfaces, e.g. a blocked one) →
    /// `normal`, `hold` → `low`. Pure so it's unit-testable and shared by the
    /// queue sort and the row accent.
    public static func of(_ decision: BossInboxDecision) -> DecisionSeverity {
        if case .unsafe = PromptSafetyClassifier.classify(
            prompt: decision.prompt,
            proposedInput: decision.proposedInput
        ) {
            return .critical
        }
        switch decision.kind {
        case .escalate:
            return .elevated
        case .autoAdvance:
            return .normal
        case .hold:
            return .low
        }
    }
}

/// Snooze-interval helpers for the inbox triage menu. Pure (clock + calendar
/// injected) so the "until end of day" arithmetic is unit-testable.
public enum WorkbenchTriageInterval {
    /// Seconds from `now` to the start of the next day in `calendar` — the
    /// "until end of day" snooze. Falls back to 24h if the calendar can't
    /// compute a next day (it always can in practice).
    public static func untilEndOfDay(
        now: Date = Date(),
        calendar: Calendar = .current,
        nextDate: ((Calendar, Date, DateComponents, Calendar.MatchingPolicy) -> Date?)? = nil
    ) -> TimeInterval {
        let resolver = nextDate ?? { calendar, date, components, policy in
            calendar.nextDate(after: date, matching: components, matchingPolicy: policy)
        }
        guard let nextDay = resolver(calendar, now, DateComponents(hour: 0, minute: 0, second: 0), .nextTime) else {
            return 86_400
        }
        return max(60, nextDay.timeIntervalSince(now))
    }
}

/// One severity-grouped section of the open inbox: a tier and the decisions in
/// it (already in queue order). Lets the UI render headed groups without
/// re-deriving severity per row.
public struct InboxSeverityGroup: Equatable, Sendable, Identifiable {
    public var severity: DecisionSeverity
    public var decisions: [BossInboxDecision]
    public var id: Int { severity.rawValue }

    public init(severity: DecisionSeverity, decisions: [BossInboxDecision]) {
        self.severity = severity
        self.decisions = decisions
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
    /// The operator's **human triage** state for this decision (orthogonal to
    /// `status`, which is the boss-side lifecycle). `nil` = open / untriaged —
    /// the default, and what every pre-triage persisted decision decodes to
    /// (synthesized Codable treats this optional as decode-if-present, mirroring
    /// how `friend` / `detailLayout` were added with no `schemaVersion` bump).
    public var triage: DecisionTriage?

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
        status: BossDecisionStatus = .recorded,
        triage: DecisionTriage? = nil
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
        self.triage = triage
    }

    /// Convenience: whether this decision is still open in the inbox at `now`
    /// (no triage, or a snooze that has elapsed). `nil` triage → open.
    public func isOpenForTriage(at now: Date) -> Bool {
        triage?.isOpen(at: now) ?? true
    }

    /// This decision's stable dedup grouping key — `entryId` when present, else a
    /// stable pseudo-key derived from `(sessionName, prompt, kind)`. Shared by the
    /// `isNewDecision` window scan (FIX 2) and `openInbox`'s collapse (FIX 3) so a
    /// nil-entry decision dedupes by the same identity in both. See
    /// `WorkspaceState.dedupGroupKey`.
    var dedupGroupKey: String {
        WorkspaceState.dedupGroupKey(entryId: entryId, sessionName: sessionName, prompt: prompt, kind: kind)
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

    /// How many of the most-recent decisions `isNewDecision` scans for a
    /// `(prompt, kind)` match before treating a decision as new. Bounded so the
    /// dedup never walks the full 200-row log, yet wide enough that interleaved
    /// prompts (A→B→A) still find the earlier A. Ample for the 1–2 live prompts a
    /// session cycles through between boss ticks.
    static let dedupScanWindow = 50

    /// Record a boss decision newest-first, trimming to the cap. Pure mutation
    /// (no persistence) so the model layer controls when to save — mirrors how
    /// the action log is appended.
    mutating func recordDecision(_ decision: BossInboxDecision) {
        decisionLog.insert(decision, at: 0)
        decisionLog = Self.trimmedToCap(decisionLog, cap: Self.decisionLogCap)
    }

    /// Whether a decision still needs the human at `now` — the same predicate the
    /// open inbox surfaces (`needsHuman` ∧ not resolved/acknowledged/active-snooze).
    /// The cap-trim treats exactly these as "open" and refuses to evict them, so a
    /// waiting session is never silently dropped. (The per-entry collapse in
    /// `openInbox` is a display concern and doesn't change retention.)
    static func isOpenEscalation(_ decision: BossInboxDecision, now: Date) -> Bool {
        needsHuman(decision) && decision.isOpenForTriage(at: now)
    }

    /// Pure cap-trim for a **newest-first** decision log. Open escalations (the
    /// ones `openInbox` surfaces) are NEVER evicted by the cap — only RESOLVED /
    /// acknowledged / audit-only rows are shed, oldest-first, until the log is at
    /// the cap. If every remaining row is open and the log is still over the cap
    /// (the all-open boundary), the open rows are kept and the log is allowed to
    /// exceed the cap. That ceiling is bounded in practice by the number of live
    /// waiting sessions (each contributes at most one open escalation per prompt),
    /// so the log never grows by unbounded *non-open* churn — the inverse-bug guard:
    /// we still shed resolved-first and stay bounded, we just refuse to drop a
    /// waiting session to do it. Stable: preserves newest-first order of survivors.
    static func trimmedToCap(_ log: [BossInboxDecision], cap: Int, now: Date = Date()) -> [BossInboxDecision] {
        guard log.count > cap else { return log }
        let overage = log.count - cap
        // Indices of evictable (non-open) rows, oldest-first. Newest-first log →
        // higher index == older, so walk from the tail.
        var evictable: [Int] = []
        for index in stride(from: log.count - 1, through: 0, by: -1) where !isOpenEscalation(log[index], now: now) {
            evictable.append(index)
            if evictable.count == overage { break }
        }
        guard !evictable.isEmpty else { return log }
        let drop = Set(evictable)
        return log.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
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

    /// Stable dedup grouping key for a decision identity, shared by `isNewDecision`
    /// (FIX 2 window scan) and `openInbox`'s collapse (FIX 3). A real entry keys by
    /// its `entryId` (so all of that session's prompts share a group and the inner
    /// `(prompt, kind)` compare distinguishes them). A nil entry — the boss
    /// referenced a session that couldn't be uniquely resolved (ambiguous/duplicate
    /// name, deleted session) — gets a STABLE pseudo-key from `(sessionName, prompt,
    /// kind)` so repeats collapse instead of piling up, while a different prompt OR
    /// kind OR target stays a distinct group. Pure so both call sites agree.
    static func dedupGroupKey(entryId: UUID?, sessionName: String?, prompt: String, kind: BossDecisionKind) -> String {
        if let entryId {
            return "id:\(entryId.uuidString)"
        }
        // Unit separator (U+001F) can't appear in a prompt/name, so the join is
        // unambiguous without escaping.
        let sep = "\u{1F}"
        return "nil:\(sessionName ?? "")\(sep)\(prompt)\(sep)\(kind.rawValue)"
    }

    /// True when no recent decision for this session already matches the same
    /// prompt + kind. Used to gate execution *before* acting, so the boss never
    /// re-sends input for a prompt it already advanced (idempotency).
    ///
    /// Scans the most-recent `dedupScanWindow` decisions in the SAME dedup group —
    /// not just the single latest row — so an interleaved A→B→A doesn't re-fire A:
    /// when A is decided, B becomes the newest row, then A reappears; a `.first`-only
    /// compare matched B (A≠B) and wrongly treated A as new. The windowed scan finds
    /// A's earlier row and reports it as not-new. Bounded by the window so the dedup
    /// never walks the full log; a match pushed past the window re-surfaces as new
    /// (the accepted bound).
    func isNewDecision(entryId: UUID?, prompt: String, kind: BossDecisionKind, sessionName: String? = nil) -> Bool {
        let group = Self.dedupGroupKey(entryId: entryId, sessionName: sessionName, prompt: prompt, kind: kind)
        var scanned = 0
        for decision in decisionLog where decision.dedupGroupKey == group {
            if decision.prompt == prompt && decision.kind == kind {
                return false
            }
            scanned += 1
            if scanned >= Self.dedupScanWindow { break }
        }
        return true
    }

    // MARK: - Human triage

    /// Set a decision's triage state (pure mutation, no persistence — mirrors
    /// `recordDecision`, so the model layer controls when to save). No-op if the
    /// id isn't in the log.
    private mutating func setTriage(_ triage: DecisionTriage?, forID id: UUID) {
        guard let index = decisionLog.firstIndex(where: { $0.id == id }) else {
            return
        }
        decisionLog[index].triage = triage
    }

    /// Operator acknowledges a decision — seen, parked, out of the open queue.
    mutating func acknowledge(decisionID id: UUID, at date: Date = Date()) {
        setTriage(.acknowledged(at: date), forID: id)
    }

    /// Snooze a decision until `date`; it stays out of the open queue until then
    /// and resurfaces once `now` passes it.
    mutating func snooze(decisionID id: UUID, until date: Date) {
        setTriage(.snoozed(until: date), forID: id)
    }

    /// Resolve a decision — dealt with, permanently out of the open queue.
    mutating func resolve(decisionID id: UUID, at date: Date = Date()) {
        setTriage(.resolved(at: date), forID: id)
    }

    // MARK: - Prioritized open inbox (read-side)

    /// Whether a decision belongs in the open inbox at all (independent of
    /// triage): the ones that actually need the human. An `escalate` always does;
    /// a `hold` does (the boss parked it for the operator to look at); an
    /// `autoAdvance` only does when it was NOT actually sent — a `recorded`/
    /// `overridden` auto-advance is a blocked or corrected one that fell back to
    /// the human, whereas an `applied` one was handled and is audit-only.
    private static func needsHuman(_ decision: BossInboxDecision) -> Bool {
        switch decision.kind {
        case .escalate, .hold:
            return true
        case .autoAdvance:
            return decision.status != .applied
        }
    }

    /// The prioritized open inbox at `now`: decisions that need the human and are
    /// neither resolved nor currently snoozed, sorted by **severity then
    /// recency** (most severe first; within a tier, newest first). This is the
    /// queue ⌘J walks and the Inbox view renders — typically 1–2 items even with
    /// ~10 mostly-dormant sessions, never the full 200-row log.
    ///
    /// De-duplicated per session (newest open decision per `entryId` wins) so a
    /// session that ticked several escalations shows once; decisions with no
    /// `entryId` are each kept (they can't be collapsed safely).
    func openInbox(now: Date = Date()) -> [BossInboxDecision] {
        var seenEntryIDs = Set<UUID>()
        // decisionLog is already newest-first, so the first open decision we see
        // for an entry is its newest — keep that one, drop older same-entry ones.
        let candidates = decisionLog.filter { decision in
            guard Self.needsHuman(decision), decision.isOpenForTriage(at: now) else {
                return false
            }
            guard let entryId = decision.entryId else {
                return true
            }
            return seenEntryIDs.insert(entryId).inserted
        }
        // Stable sort by severity desc, then recency desc. `enumerated` index is
        // the tie-breaker so equal (severity, occurredAt) keeps newest-first
        // log order deterministically.
        return candidates.enumerated().sorted { lhs, rhs in
            let ls = DecisionSeverity.of(lhs.element)
            let rs = DecisionSeverity.of(rhs.element)
            if ls != rs {
                return ls > rs
            }
            if lhs.element.occurredAt != rhs.element.occurredAt {
                return lhs.element.occurredAt > rhs.element.occurredAt
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// `openInbox(now:)` partitioned into severity-headed groups (most severe
    /// first), each preserving queue order. Empty tiers are omitted. Lets the
    /// Inbox view render sections without re-deriving severity per row.
    func openInboxGroups(now: Date = Date()) -> [InboxSeverityGroup] {
        let queue = openInbox(now: now)
        return DecisionSeverity.allCases.reversed().compactMap { severity in
            let items = queue.filter { DecisionSeverity.of($0) == severity }
            return items.isEmpty ? nil : InboxSeverityGroup(severity: severity, decisions: items)
        }
    }

    /// Count of open inbox items at `now` — for the ⌘K subtitle / badge ("2
    /// sessions need a decision") without materializing the full sort.
    func openInboxCount(now: Date = Date()) -> Int {
        openInbox(now: now).count
    }
}
