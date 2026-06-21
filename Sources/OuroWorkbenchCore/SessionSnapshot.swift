import Foundation

/// Machine-readable owner descriptor for a `SessionSnapshot`.
///
/// `kind` is `"human"` or `"agent"`; `name` carries the agent name for an
/// agent-owned session and is omitted for the human operator.
public struct SessionOwnerSnapshot: Codable, Equatable, Sendable {
    public var kind: String
    public var name: String?

    public init(kind: String, name: String? = nil) {
        self.kind = kind
        self.name = name
    }
}

/// A flat, machine-readable view of one Workbench session, intended for an
/// outbound MCP client (e.g. the Ouro harness driving coding sessions through
/// Workbench terminals) rather than the boss's human-readable check-in prompt.
///
/// Fields map directly onto `ProcessEntry` plus its most-recent `ProcessRun`:
/// `status` is the latest run's `ProcessStatus` raw value (or `configured` when
/// the session has never run); `attention` is the entry's `AttentionState`;
/// `needsHuman` mirrors `AttentionState.needsHuman`. Optional fields are omitted
/// from the encoded JSON when nil (synthesized `encodeIfPresent`), so a client
/// treats an absent key as "unknown / not applicable".
public struct SessionSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var group: String?
    public var owner: SessionOwnerSnapshot
    public var kind: String
    public var status: String
    public var attention: String
    /// The short "why" line for a non-idle `attention` (the prompt the agent is
    /// waiting on / the error it's stuck on). Mirrors `ProcessEntry.attentionReason`
    /// so the boss reads the SAME reason the operator sees on the detail surface.
    /// Omitted from the encoded JSON when nil.
    public var attentionReason: String?
    /// The inline waiting-prompt snippet — the tail of the session's transcript
    /// the operator-facing check-in path already computes for a human-owned
    /// session parked at a prompt (#U24). Lets the boss triage the attention
    /// queue in one call without a separate `workbench_transcript_tail`. Carried
    /// only on rows where it was supplied (a human-owned waiting/blocked row);
    /// omitted from the encoded JSON when nil.
    public var attentionPrompt: String?
    /// Who is driving this session (#U25b): `"human"` for an operator-owned
    /// session, `"agent"` for one owned by an agent's own loop. Lets the boss tell
    /// an agent-driven prompt from a human-attention item directly off the row,
    /// without parsing the preamble. Mirrors `owner.kind`, surfaced as a top-level
    /// field for the actionable/needsHuman semantics that hang off it.
    public var driver: String
    /// Whether THIS row is a human-attention item the boss should act on / relay
    /// (#U25b). False for an agent-owned session merely parked at or blocked in its
    /// OWN loop (that's the agent's turn, not the human's); true for a human-owned
    /// waiting/blocked session and for a genuine boss-raised `needsBossReview`
    /// (even on an agent-owned session). Equal to `needsHuman`, named for the
    /// "is this mine to drive?" question the boss asks.
    public var actionable: Bool
    public var needsHuman: Bool
    public var trust: String
    public var autoResume: Bool
    public var isArchived: Bool
    public var isPinned: Bool
    public var pid: Int?
    public var exitCode: Int?
    public var workingDirectory: String
    public var transcriptPath: String?
    public var startedAt: Date?
    public var lastOutputAt: Date?

    public init(
        id: String,
        name: String,
        group: String? = nil,
        owner: SessionOwnerSnapshot,
        kind: String,
        status: String,
        attention: String,
        attentionReason: String? = nil,
        attentionPrompt: String? = nil,
        // Default to the human/actionable interpretation so callers that build a
        // snapshot for a non-attention purpose (e.g. the SessionHealthProbe
        // convenience input) need not restate them; the sessions renderer always
        // passes both explicitly, owner-aware (#U25b).
        driver: String = "human",
        actionable: Bool = false,
        needsHuman: Bool,
        trust: String,
        autoResume: Bool,
        isArchived: Bool,
        isPinned: Bool,
        pid: Int? = nil,
        exitCode: Int? = nil,
        workingDirectory: String,
        transcriptPath: String? = nil,
        startedAt: Date? = nil,
        lastOutputAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.owner = owner
        self.kind = kind
        self.status = status
        self.attention = attention
        self.attentionReason = attentionReason
        self.attentionPrompt = attentionPrompt
        self.driver = driver
        self.actionable = actionable
        self.needsHuman = needsHuman
        self.trust = trust
        self.autoResume = autoResume
        self.isArchived = isArchived
        self.isPinned = isPinned
        self.pid = pid
        self.exitCode = exitCode
        self.workingDirectory = workingDirectory
        self.transcriptPath = transcriptPath
        self.startedAt = startedAt
        self.lastOutputAt = lastOutputAt
    }
}

/// Builds `SessionSnapshot`s from a `WorkspaceState`. Pure (no I/O), so it's
/// unit-testable and reusable by both the MCP server (`workbench_sessions`) and
/// the app.
public struct WorkbenchSessionsRenderer {
    public init() {}

    /// - Parameters:
    ///   - state: the workspace state to read.
    ///   - owner: when set, return only sessions owned by the agent of this
    ///     name (`SessionOwner.agentName == owner`). Human-owned sessions are
    ///     excluded. Omit to include every owner.
    ///   - name: when set, return only sessions whose name matches
    ///     case-insensitively. Used by a client to resolve the id of a session
    ///     it just created under a unique name.
    ///   - attention: when set, return only sessions whose `AttentionState`
    ///     raw value is in this set (#U24) — e.g. `["waitingOnHuman","blocked",
    ///     "needsBossReview"]` to fetch just the attention queue in one round-trip,
    ///     never receiving idle/active rows. Unknown raw values simply match
    ///     nothing. Omit to include every attention state.
    ///   - includeArchived: when false (default), archived sessions are omitted.
    ///   - promptSnippets: per-entry inline waiting-prompt text (#U24) the caller
    ///     computed from the transcript tail (the MCP server reads the files; this
    ///     pure renderer stays I/O-free). A snippet is attached to its row's
    ///     `attentionPrompt`; rows without one carry nil.
    public func snapshots(
        state: WorkspaceState,
        owner: String? = nil,
        name: String? = nil,
        attention: Set<String>? = nil,
        includeArchived: Bool = false,
        promptSnippets: [UUID: String] = [:]
    ) -> [SessionSnapshot] {
        let runsByEntry = Dictionary(grouping: state.processRuns, by: { $0.entryId })
        let groupNamesById = Dictionary(
            state.projects.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        return state.processEntries.compactMap { entry -> SessionSnapshot? in
            if !includeArchived, entry.isArchived { return nil }
            if let owner, entry.owner.agentName != owner { return nil }
            if let name, entry.name.caseInsensitiveCompare(name) != .orderedSame { return nil }
            if let attention, !attention.contains(entry.attention.rawValue) { return nil }

            let latest = runsByEntry[entry.id]?.sorted(by: ProcessRun.isMoreRecent).first
            let ownerSnapshot: SessionOwnerSnapshot
            switch entry.owner {
            case .human:
                ownerSnapshot = SessionOwnerSnapshot(kind: "human")
            case let .agent(agentName):
                ownerSnapshot = SessionOwnerSnapshot(kind: "agent", name: agentName)
            }
            // #U25b: an agent-owned session driven by its OWN loop is not a
            // human-attention item, so needsHuman/actionable are owner-aware — the
            // row's data alone tells the boss "this is the agent's turn, hold"
            // without reading the preamble. A boss-raised needsBossReview stays
            // actionable even on an agent-owned session.
            let actionable = entry.attention.isHumanAttention(owner: entry.owner)

            return SessionSnapshot(
                id: entry.id.uuidString,
                name: entry.name,
                group: groupNamesById[entry.projectId],
                owner: ownerSnapshot,
                kind: entry.kind.rawValue,
                status: (latest?.status ?? .configured).rawValue,
                attention: entry.attention.rawValue,
                attentionReason: entry.attentionReason,
                attentionPrompt: promptSnippets[entry.id],
                driver: ownerSnapshot.kind,
                actionable: actionable,
                needsHuman: actionable,
                trust: entry.trust.rawValue,
                autoResume: entry.autoResume,
                isArchived: entry.isArchived,
                isPinned: entry.isPinned,
                pid: (latest?.pid).map { Int($0) },
                exitCode: (latest?.exitCode).map { Int($0) },
                workingDirectory: entry.workingDirectory,
                transcriptPath: latest?.transcriptPath,
                startedAt: latest?.startedAt,
                lastOutputAt: latest?.lastOutputAt
            )
        }
    }
}

/// The boss's one-call attention queue (#U24): the sessions that need a human,
/// each with enough context to triage (id, name, group, attention, the U10
/// `attentionReason` why-line, and — for a human-owned waiting/blocked row — the
/// inline `attentionPrompt` snippet), returned in a sensible triage order so the
/// boss reports "what's waiting on me" in a single cheap round-trip instead of
/// fetching the whole machine and re-deriving the subset LLM-side every poll.
///
/// Pure (no I/O): the transcript-tail prompts are computed by the MCP server and
/// passed in as `promptSnippets`, the same map `workbench_status` builds, so the
/// queue row's prompt is the SAME text the operator-facing path shows. The
/// `attention`-set filter is the one `WorkbenchSessionsRenderer` exposes, so the
/// alias and `workbench_sessions(attention:…)` can never disagree on membership.
public struct WorkbenchAttentionQueueRenderer {
    /// The MCP tool name — single-sourced so dispatch, the tool definition, and
    /// the boss-tools catalog can't drift.
    public static let toolName = "workbench_attention_queue"

    /// The default attention states that count as "needs a human": the three
    /// `AttentionState` raw values whose `needsHuman` is true. This is exactly the
    /// set `workbench_sessions(attention:…)` would take to fetch the queue.
    public static let needsHumanAttention: Set<String> = ["waitingOnHuman", "blocked", "needsBossReview"]

    public static let toolDescription = """
        One-call attention queue (#U24): the sessions that need a human right now, each with enough context to triage in a single round-trip — no fetching the whole machine and re-deriving the subset. Returns {sessions:[SessionSnapshot]} filtered to attention in {waitingOnHuman,blocked,needsBossReview}, ordered blocked → waitingOnHuman → needsBossReview then freshest-first. Each row carries the U10 `attentionReason` why-line and, for a human-owned waiting/blocked row, the inline `attentionPrompt` transcript snippet (the same text the operator sees), so you can report what each session is asking without a separate workbench_transcript_tail. Idle/active and archived sessions are never returned. After you queue a fix via workbench_request_action, re-read this (or poll workbench_action_result with the requestId) to confirm the row cleared.
        """

    public init() {}

    /// The attention queue for the boss: every non-archived session whose
    /// attention needs a human, ordered for triage. `promptSnippets` is the
    /// MCP-computed transcript-tail map (keyed by entry id).
    public func queue(
        state: WorkspaceState,
        promptSnippets: [UUID: String] = [:]
    ) -> [SessionSnapshot] {
        WorkbenchSessionsRenderer()
            .snapshots(
                state: state,
                attention: Self.needsHumanAttention,
                includeArchived: false,
                promptSnippets: promptSnippets
            )
            // #U25b: an agent-owned session parked at / blocked in its OWN loop has
            // a needs-human attention raw value but is the AGENT's turn, not the
            // human's — `actionable` is owner-aware, so filtering on it keeps an
            // agent's own loop out of the human's attention queue while a genuine
            // boss-raised needsBossReview (actionable even when agent-owned) stays.
            .filter(\.actionable)
            .sorted(by: Self.triageOrder)
    }

    /// Triage order: the hardest stop first (`blocked`), then a session parked at
    /// a prompt (`waitingOnHuman`), then the boss's softer review flag
    /// (`needsBossReview`); within one attention bucket, freshest-first by
    /// `lastOutputAt` then `startedAt`, name- and id-tiebroken so the order is
    /// fully deterministic between polls (two polls can never disagree).
    static func triageOrder(_ lhs: SessionSnapshot, _ rhs: SessionSnapshot) -> Bool {
        let lhsRank = attentionRank(lhs.attention)
        let rhsRank = attentionRank(rhs.attention)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        let lhsOutput = negated(lhs.lastOutputAt)
        let rhsOutput = negated(rhs.lastOutputAt)
        if lhsOutput != rhsOutput { return lhsOutput < rhsOutput }
        let lhsStarted = negated(lhs.startedAt)
        let rhsStarted = negated(rhs.startedAt)
        if lhsStarted != rhsStarted { return lhsStarted < rhsStarted }
        let lhsName = lhs.name.lowercased()
        let rhsName = rhs.name.lowercased()
        if lhsName != rhsName { return lhsName < rhsName }
        return lhs.id < rhs.id
    }

    /// Lower rank sorts first. An unexpected attention value (the renderer's
    /// filter only admits the three needs-human states, so this is defensive)
    /// sorts last so it can never jump ahead of a real queue item.
    private static func attentionRank(_ attention: String) -> Int {
        switch attention {
        case "blocked": return 0
        case "waitingOnHuman": return 1
        case "needsBossReview": return 2
        default: return 3
        }
    }

    /// `-since1970` for a present date (newer → more negative → sorts first);
    /// `.greatestFiniteMagnitude` for a missing date (sorts last).
    private static func negated(_ date: Date?) -> Double {
        guard let date else { return .greatestFiniteMagnitude }
        return -date.timeIntervalSince1970
    }
}
