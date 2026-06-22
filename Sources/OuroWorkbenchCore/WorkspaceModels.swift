import Foundation

public enum ProcessKind: String, Codable, Sendable {
    case command
    case shell
    case terminalAgent
    case ouroBoss

    // Unknown raw values (e.g. a kind added by a newer build) decode to
    // `.command` instead of throwing — schema drift shouldn't sink the row.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProcessKind(rawValue: raw) ?? .command
    }
}

public enum ProcessTrust: String, Codable, Sendable {
    case trusted
    case untrusted

    // Unknown decodes to the safe default (`.untrusted`).
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProcessTrust(rawValue: raw) ?? .untrusted
    }
}

public enum ProcessStatus: String, Codable, Sendable {
    case configured
    case running
    case exited
    case waitingForInput
    case needsRecovery
    case manualActionNeeded

    // Unknown decodes to `.configured` (neutral, not-running) rather than
    // throwing on a status added by a newer build.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProcessStatus(rawValue: raw) ?? .configured
    }
}

public enum AttentionState: String, Codable, Sendable {
    case idle
    case active
    case waitingOnHuman
    case blocked
    case needsBossReview

    // Unknown decodes to `.idle`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AttentionState(rawValue: raw) ?? .idle
    }

    /// Whether this state means the session is asking for the operator: it's
    /// waiting at a prompt, the boss flagged it for review, or it's blocked.
    /// Drives "jump to the next session that needs me" navigation.
    public var needsHuman: Bool {
        switch self {
        case .waitingOnHuman, .needsBossReview, .blocked:
            return true
        case .idle, .active:
            return false
        }
    }

    /// Whether this attention is a HUMAN-attention item given who drives the
    /// session (#U25b). The owner is the discriminator the bare `needsHuman` can't
    /// see: an agent-owned session merely parked at — or stuck in — its OWN loop
    /// (`waitingOnHuman` / `blocked`) is the agent's turn, not the human's, so it
    /// is NOT a human-attention item and must stay out of the boss's
    /// waiting-on-you bucket. A `needsBossReview` flag is a genuine boss-RAISED
    /// review item, so it remains a human item even on an agent-owned session —
    /// suppressing the agent's own loop must never hide a real review.
    /// `idle` / `active` are never human items.
    public func isHumanAttention(owner: SessionOwner) -> Bool {
        switch self {
        case .needsBossReview:
            return true
        case .waitingOnHuman, .blocked:
            return owner.agentName == nil
        case .idle, .active:
            return false
        }
    }
}

public struct BossAgentSelection: Codable, Equatable, Sendable {
    public var agentName: String
    public var scope: String

    /// The default boss is UNRESOLVED (empty), never a hardcoded agent name. A
    /// machine's boss is resolved from the installed-agent inventory at runtime
    /// (see `BossAutoResolution`): zero agents route to acquisition, exactly one
    /// is adopted automatically, more than one forces an explicit human choice.
    /// Hardcoding a name here would land first-run on a non-existent agent on
    /// every machine that doesn't happen to have an agent by that name.
    public init(agentName: String = "", scope: String = "machine") {
        self.agentName = agentName
        self.scope = scope
    }
}

public struct WorkbenchProject: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var rootPath: String
    public var boss: BossAgentSelection
    /// Optional color tag (raw value of `WorkbenchGroupColor`). Absent / nil
    /// renders the group untagged. Synthesized Codable treats this as
    /// decode-if-present, so existing persisted state loads unchanged.
    public var colorTag: String?
    /// Default friend new sessions in this group inherit when they don't set
    /// their own. Absent / nil leaves sessions unassigned. Synthesized Codable
    /// decodes this if-present, so existing persisted state loads unchanged.
    public var defaultFriend: SessionFriend?

    public init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        boss: BossAgentSelection = BossAgentSelection(),
        colorTag: String? = nil,
        defaultFriend: SessionFriend? = nil
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.boss = boss
        self.colorTag = colorTag
        self.defaultFriend = defaultFriend
    }
}

/// Who owns / drives a session — the human operator, or a named agent that
/// spawned it through Workbench. Distinct from `friend` (whose *preferences*
/// the boss applies): `owner` is who controls the session.
public enum SessionOwner: Codable, Equatable, Sendable {
    case human
    case agent(name: String)

    public var agentName: String? {
        if case let .agent(name) = self { return name }
        return nil
    }

    /// Short label for the UI ("You" for human, the agent name otherwise).
    public var displayName: String {
        switch self {
        case .human: return "You"
        case let .agent(name): return name
        }
    }

    /// Sidebar indicator for an agent-owned session — nil for the human operator
    /// (no badge), an SF Symbol + the agent name for an agent.
    public var sidebarBadge: (symbol: String, label: String)? {
        switch self {
        case .human: return nil
        case let .agent(name): return ("cpu", name)
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, name }
    private enum Kind: String, Codable {
        case human, agent

        // Unknown `kind` (forward schema drift — a future build adds an owner
        // kind) decodes to `.human` rather than throwing. A throw here is
        // worse than a wrong field: `ProcessEntry` is decoded via
        // `FailableDecodable`, so the throw drops the ENTIRE session row, not
        // just the owner. Matches every other persisted enum in this file
        // (`ProcessKind`, `ProcessStatus`, `AttentionState`, `ProcessTrust`).
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .human
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .human: self = .human
        case .agent:
            // A malformed agent owner missing its `name` falls back to the
            // human operator rather than throwing — same don't-drop-the-row
            // policy as an unknown kind.
            if let name = try c.decodeIfPresent(String.self, forKey: .name) {
                self = .agent(name: name)
            } else {
                self = .human
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .human:
            try c.encode(Kind.human, forKey: .kind)
        case let .agent(name):
            try c.encode(Kind.agent, forKey: .kind)
            try c.encode(name, forKey: .name)
        }
    }
}

public struct ProcessEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var projectId: UUID
    public var name: String
    public var kind: ProcessKind
    public var agentKind: TerminalAgentKind?
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String
    public var trust: ProcessTrust
    public var autoResume: Bool
    public var isArchived: Bool
    /// User-pinned to the top of its group in the sidebar. Defaults to false;
    /// decoded with decodeIfPresent so pre-pin state loads unchanged.
    public var isPinned: Bool
    public var attention: AttentionState
    /// A short, bounded human-readable "why" line for the current non-idle
    /// `attention` — the prompt the agent is waiting on, or the error it's stuck
    /// on (see `AttentionSignalDetector.classifyWithReason`). The live detail
    /// banner and the boss-facing `SessionSnapshot` both read THIS string, so the
    /// operator and the boss agree on why a session is waiting. Nil when there's
    /// no derived reason (idle/active, or no informative line). Decoded
    /// if-present so pre-U10 state loads unchanged.
    public var attentionReason: String?
    public var lastSummary: String?
    public var notes: String?
    /// The friend (human or agent) this session acts for / as, governing whose
    /// preferences the boss applies. Absent / nil means unassigned — the boss
    /// never auto-advances an unassigned session. Decoded if-present so
    /// pre-friend state loads unchanged.
    public var friend: SessionFriend?
    /// Who owns / drives this session — the human operator or a named agent.
    /// Defaults to `.human`; decoded if-present so pre-owner state loads
    /// unchanged.
    public var owner: SessionOwner
    /// FORWARD MEMORY (Slice 6). When Workbench owns a session's launch it
    /// records the originating discovery `{harness, sessionId}` here so the next
    /// `AgentSessionScanner.scan` finds the session NATIVELY (via
    /// `discoverFromWorkbench`) instead of re-inferring it from disk/process
    /// scraping. Both are additive + OPTIONAL and decoded if-present, so a
    /// `workspace-state.json` written before Slice 6 (which lacks these keys)
    /// still loads with them nil — never a hardcoded harness. Nil means "not
    /// launched from a discovered session" (the common operator-typed case).
    public var discoveredHarness: AgentHarness?
    public var discoveredSessionId: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case projectId
        case name
        case kind
        case agentKind
        case executable
        case arguments
        case workingDirectory
        case trust
        case autoResume
        case isArchived
        case isPinned
        case attention
        case attentionReason
        case lastSummary
        case notes
        case friend
        case owner
        case discoveredHarness
        case discoveredSessionId
    }

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        name: String,
        kind: ProcessKind,
        agentKind: TerminalAgentKind? = nil,
        executable: String,
        arguments: [String] = [],
        workingDirectory: String,
        trust: ProcessTrust = .trusted,
        autoResume: Bool = false,
        isArchived: Bool = false,
        isPinned: Bool = false,
        attention: AttentionState = .idle,
        attentionReason: String? = nil,
        lastSummary: String? = nil,
        notes: String? = nil,
        friend: SessionFriend? = nil,
        owner: SessionOwner = .human,
        discoveredHarness: AgentHarness? = nil,
        discoveredSessionId: String? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.kind = kind
        self.agentKind = agentKind
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.trust = trust
        self.autoResume = autoResume
        self.isArchived = isArchived
        self.isPinned = isPinned
        self.attention = attention
        self.attentionReason = attentionReason
        self.lastSummary = lastSummary
        self.notes = notes
        self.friend = friend
        self.owner = owner
        self.discoveredHarness = discoveredHarness
        self.discoveredSessionId = discoveredSessionId
    }

    public var trimmedNotes: String? {
        guard let notes else {
            return nil
        }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.projectId = try container.decode(UUID.self, forKey: .projectId)
        self.name = try container.decode(String.self, forKey: .name)
        self.kind = try container.decode(ProcessKind.self, forKey: .kind)
        self.agentKind = try container.decodeIfPresent(TerminalAgentKind.self, forKey: .agentKind)
        self.executable = try container.decode(String.self, forKey: .executable)
        self.arguments = try container.decode([String].self, forKey: .arguments)
        self.workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        self.trust = try container.decode(ProcessTrust.self, forKey: .trust)
        self.autoResume = try container.decode(Bool.self, forKey: .autoResume)
        self.isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        self.isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        self.attention = try container.decodeIfPresent(AttentionState.self, forKey: .attention) ?? .idle
        self.attentionReason = try container.decodeIfPresent(String.self, forKey: .attentionReason)
        self.lastSummary = try container.decodeIfPresent(String.self, forKey: .lastSummary)
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes)
        self.friend = try container.decodeIfPresent(SessionFriend.self, forKey: .friend)
        self.owner = try container.decodeIfPresent(SessionOwner.self, forKey: .owner) ?? .human
        // Forward memory (Slice 6): absent in every pre-Slice-6 state file →
        // nil, no schema bump. AgentHarness's own decoder maps an unknown raw
        // value to `.custom`, so a record from a newer build still loads.
        self.discoveredHarness = try container.decodeIfPresent(AgentHarness.self, forKey: .discoveredHarness)
        self.discoveredSessionId = try container.decodeIfPresent(String.self, forKey: .discoveredSessionId)
    }
}

public struct ProcessRun: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var entryId: UUID
    public var pid: Int32?
    public var status: ProcessStatus
    public var startedAt: Date
    public var endedAt: Date?
    public var exitCode: Int32?
    public var rawExitStatus: Int32?
    public var terminalSessionId: String?
    public var transcriptPath: String?
    public var lastOutputAt: Date?

    public init(
        id: UUID = UUID(),
        entryId: UUID,
        pid: Int32? = nil,
        status: ProcessStatus,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        exitCode: Int32? = nil,
        rawExitStatus: Int32? = nil,
        terminalSessionId: String? = nil,
        transcriptPath: String? = nil,
        lastOutputAt: Date? = nil
    ) {
        self.id = id
        self.entryId = entryId
        self.pid = pid
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.rawExitStatus = rawExitStatus
        self.terminalSessionId = terminalSessionId
        self.transcriptPath = transcriptPath
        self.lastOutputAt = lastOutputAt
    }

    /// Deterministic "is `lhs` more recent than `rhs`" ordering for runs.
    /// Newer `startedAt` wins; ties (equal timestamps — common when runs are
    /// created in a tight loop or restored from second-granularity dates)
    /// break on `id` so every call site — summary, recovery planner, drill,
    /// prompt builder — agrees on which run is "latest" instead of depending
    /// on array order (`sorted(by: >)` is not a stable tiebreak).
    public static func isMoreRecent(_ lhs: ProcessRun, _ rhs: ProcessRun) -> Bool {
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt > rhs.startedAt
        }
        return lhs.id.uuidString > rhs.id.uuidString
    }
}

public struct WorkbenchActionLogEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var occurredAt: Date
    public var source: String
    public var action: String
    public var targetEntryId: UUID?
    public var targetName: String?
    public var result: String
    public var succeeded: Bool
    /// The originating `WorkbenchActionRequest.id` when this log entry recorded a
    /// queued boss request the app drained (#U24), so the boss's queued request
    /// and the operator's audit entry share ONE key. Nil for actions the operator
    /// took directly (no queued request) and for pre-U24 state, where synthesized
    /// Codable decodes the absent key as nil so old logs load unchanged.
    public var requestId: UUID?

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        source: String,
        action: String,
        targetEntryId: UUID? = nil,
        targetName: String? = nil,
        result: String,
        succeeded: Bool,
        requestId: UUID? = nil
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.source = source
        self.action = action
        self.targetEntryId = targetEntryId
        self.targetName = targetName
        self.result = result
        self.succeeded = succeeded
        self.requestId = requestId
    }
}

/// Persisted shape of the detail pane's split (W5 increment 2). Mirrors the
/// App target's in-memory `DetailSplitState` + `activePaneID`, but lives in
/// Core so it can ride on `WorkspaceState` and be unit-tested without the App
/// target. The App maps its `DetailSplitAxis` / `DetailPaneID` to/from these
/// Core enums on save/restore.
///
/// Increment 2 persists exactly one split (no recursive nesting / tabs /
/// multi-window — those remain follow-ups, see
/// `_planning/w5-split-panes-multiwindow.md`). The primary pane always shows
/// the workspace's `selectedEntryId`, so only the *secondary* pane's session
/// needs storing; `secondaryEntryID == nil` means the secondary pane was an
/// empty picker.
///
/// Pure value type → trivially `Sendable`; no actor isolation, no reference
/// semantics. `WorkspaceState.detailLayout` is `nil` for the classic
/// single-pane layout (and for every pre-increment-2 state file).
public struct PaneLayoutState: Codable, Equatable, Sendable {
    /// Orientation of the single split. Mirrors the App's `DetailSplitAxis`.
    public enum Axis: String, Codable, Sendable {
        /// Side-by-side panes, vertical divider ("Split Right").
        case vertical
        /// Stacked panes, horizontal divider ("Split Down").
        case horizontal

        // Unknown raw value (a future axis) decodes to `.vertical` rather than
        // throwing and dropping the whole layout — matches the lenient-enum
        // posture of every other persisted enum in this file.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Axis(rawValue: raw) ?? .vertical
        }
    }

    /// Which pane held logical focus. Mirrors the App's `DetailPaneID`.
    public enum Focus: String, Codable, Sendable {
        case primary
        case secondary

        // Unknown raw value decodes to `.primary` (the always-valid pane).
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Focus(rawValue: raw) ?? .primary
        }
    }

    public var axis: Axis
    /// The session shown in the secondary pane, or `nil` for an empty picker.
    public var secondaryEntryID: UUID?
    /// Which pane was focused when the layout was saved.
    public var activePane: Focus

    public init(axis: Axis, secondaryEntryID: UUID?, activePane: Focus) {
        self.axis = axis
        self.secondaryEntryID = secondaryEntryID
        self.activePane = activePane
    }

    /// Resolve a restored layout against the sessions that actually exist in
    /// the loaded workspace, returning the layout to apply or `nil` to start
    /// single-pane. This is the pure heart of "restore degrades gracefully":
    ///
    /// - If the secondary pane references a session that no longer exists, is
    ///   archived, or equals the restored primary selection (`selectedEntryId`
    ///   — the one-session-per-pane invariant), the stored `secondaryEntryID`
    ///   is dropped (set to `nil`), leaving the split open with an empty
    ///   secondary picker rather than a duplicate/dangling pane. The split
    ///   itself is preserved because the operator deliberately opened it.
    /// - If the focus pointed at a secondary pane that just lost its session,
    ///   focus falls back to `.primary` (the always-valid pane).
    /// - The axis is always preserved.
    ///
    /// Returning the split (with a cleared secondary) rather than `nil` keeps
    /// the operator's chosen two-up layout across relaunch even when the
    /// secondary agent's pty is gone — the empty picker lets them re-pick.
    ///
    /// - Parameters:
    ///   - selectedEntryId: the restored primary selection (already validated
    ///     against existing entries by the caller).
    ///   - liveEntryIDs: ids of sessions eligible to mount in a pane — present
    ///     in the workspace and not archived. A secondary not in this set is
    ///     treated as missing.
    public func resolved(
        selectedEntryId: UUID?,
        liveEntryIDs: Set<UUID>
    ) -> PaneLayoutState {
        var resolved = self
        if let secondary = secondaryEntryID,
           secondary == selectedEntryId || !liveEntryIDs.contains(secondary) {
            // Stale, archived, or collides with the primary pane — drop it to
            // an empty picker rather than mounting a dangling/duplicate pane.
            resolved.secondaryEntryID = nil
        }
        if resolved.secondaryEntryID == nil, resolved.activePane == .secondary {
            // The focused pane just lost its session; fall back to the
            // always-valid primary so the focus ring lands somewhere real.
            resolved.activePane = .primary
        }
        return resolved
    }
}

/// What lenient decode silently dropped on a load. `WorkspaceState.init(from:)`
/// turns per-element decode failures into skipped rows (so one corrupt row can't
/// sink the whole workspace) — this report SURFACES those drops so the load path
/// can salvage the original bytes before the survivors-only state is re-saved.
///
/// Non-persisted: it describes one decode pass, not durable state, so it's
/// excluded from `WorkspaceState.CodingKeys` and defaults to lossless.
public struct DecodeReport: Equatable, Sendable {
    /// Total rows dropped across all leniently-decoded collections.
    public var skippedRowCount: Int
    /// Per-collection drop counts, keyed by the `CodingKeys` string (e.g.
    /// `"projects"`). Only collections that actually dropped a row appear.
    public var skippedByCollection: [String: Int]

    public init(skippedRowCount: Int = 0, skippedByCollection: [String: Int] = [:]) {
        self.skippedRowCount = skippedRowCount
        self.skippedByCollection = skippedByCollection
    }

    /// `true` iff decode dropped at least one row — i.e. the loaded state is a
    /// strict subset of what's on disk and re-saving it would lose data.
    public var isLossy: Bool { skippedRowCount > 0 }
}

/// Whether it's safe to re-save the just-loaded state over the original file, or
/// whether the original must be salvaged first because the decode was lossy.
public enum PostLoadDecision: Equatable {
    case safeToResave
    case salvageBeforeResave(reason: String)
}

/// `.salvageBeforeResave` iff the report is lossy (any dropped row) — otherwise
/// `.safeToResave`. The reason names the drop count so the audit log + operator
/// message are honest about how much was at risk.
public func postLoadDecision(for report: DecodeReport) -> PostLoadDecision {
    guard report.isLossy else {
        return .safeToResave
    }
    return .salvageBeforeResave(reason: "decode dropped \(report.skippedRowCount) row(s)")
}

public struct WorkspaceState: Codable, Equatable, Sendable {
    /// The state-file schema version this build reads and writes. The single
    /// source of truth for the version check — `WorkbenchStore.load` rejects any
    /// file whose `schemaVersion` differs, and `degradedReadReason` reports it as
    /// the "supported" version when a newer file is found. Bump in lockstep with
    /// a breaking schema change.
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var boss: BossAgentSelection
    public var bossWatchEnabled: Bool
    public var bossPaneCollapsed: Bool
    public var selectedProjectId: UUID?
    public var selectedEntryId: UUID?
    public var projects: [WorkbenchProject]
    public var processEntries: [ProcessEntry]
    public var processRuns: [ProcessRun]
    public var actionLog: [WorkbenchActionLogEntry]
    /// Durable, newest-first audit of boss decisions about waiting sessions —
    /// what the boss decided and why. Bounded like `actionLog`; decoded
    /// leniently and present-or-empty so existing state loads unchanged.
    public var decisionLog: [BossInboxDecision]
    /// Persisted detail-pane split (W5 increment 2). `nil` = classic single
    /// pane (and every pre-increment-2 state file, which lacks the key).
    /// Additive, decoded if-present — no `schemaVersion` bump, so existing
    /// operators' state loads unchanged. See `PaneLayoutState`.
    public var detailLayout: PaneLayoutState?
    public var updatedAt: Date
    /// Non-persisted account of what lenient decode dropped while loading THIS
    /// instance. Excluded from `CodingKeys` (it describes a decode pass, not
    /// durable state) and defaults to lossless, so a memberwise-built or
    /// re-encoded state always round-trips equal. Read by the load path to
    /// decide whether to salvage the original before re-saving the survivors.
    public var decodeReport: DecodeReport = DecodeReport()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case boss
        case bossWatchEnabled
        case bossPaneCollapsed
        case selectedProjectId
        case selectedEntryId
        case projects
        case processEntries
        case processRuns
        case actionLog
        case decisionLog
        case detailLayout
        case updatedAt
    }

    public init(
        schemaVersion: Int = 1,
        boss: BossAgentSelection = BossAgentSelection(),
        bossWatchEnabled: Bool = true,
        bossPaneCollapsed: Bool = true,
        selectedProjectId: UUID? = nil,
        selectedEntryId: UUID? = nil,
        projects: [WorkbenchProject] = [],
        processEntries: [ProcessEntry] = [],
        processRuns: [ProcessRun] = [],
        actionLog: [WorkbenchActionLogEntry] = [],
        decisionLog: [BossInboxDecision] = [],
        detailLayout: PaneLayoutState? = nil,
        updatedAt: Date = Date(),
        decodeReport: DecodeReport = DecodeReport()
    ) {
        self.schemaVersion = schemaVersion
        self.boss = boss
        self.bossWatchEnabled = bossWatchEnabled
        self.bossPaneCollapsed = bossPaneCollapsed
        self.selectedProjectId = selectedProjectId
        self.selectedEntryId = selectedEntryId
        self.projects = projects
        self.processEntries = processEntries
        self.processRuns = processRuns
        self.actionLog = actionLog
        self.decisionLog = decisionLog
        self.detailLayout = detailLayout
        self.updatedAt = updatedAt
        self.decodeReport = decodeReport
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.boss = try container.decode(BossAgentSelection.self, forKey: .boss)
        self.bossWatchEnabled = try container.decodeIfPresent(Bool.self, forKey: .bossWatchEnabled) ?? true
        self.bossPaneCollapsed = try container.decodeIfPresent(Bool.self, forKey: .bossPaneCollapsed) ?? false
        self.selectedProjectId = try container.decodeIfPresent(UUID.self, forKey: .selectedProjectId)
        self.selectedEntryId = try container.decodeIfPresent(UUID.self, forKey: .selectedEntryId)
        // Decode the collections leniently: a single corrupt or
        // schema-drifted element is skipped rather than throwing and taking
        // the entire workspace down with it (which, combined with the load
        // catch path, used to wipe the user's setup). F5: each genuine drop is
        // now ATTRIBUTED into `decodeReport` so the load path can salvage the
        // original bytes before re-saving the survivors-only state.
        var report = DecodeReport()
        self.projects = try container.decodeLenientArray(
            WorkbenchProject.self, forKey: .projects, into: &report, collection: "projects"
        )
        self.processEntries = try container.decodeLenientArray(
            ProcessEntry.self, forKey: .processEntries, into: &report, collection: "processEntries"
        )
        self.processRuns = try container.decodeLenientArray(
            ProcessRun.self, forKey: .processRuns, into: &report, collection: "processRuns"
        )
        self.actionLog = try container.decodeLenientArray(
            WorkbenchActionLogEntry.self, forKey: .actionLog, into: &report, collection: "actionLog"
        )
        self.decisionLog = try container.decodeLenientArray(
            BossInboxDecision.self, forKey: .decisionLog, into: &report, collection: "decisionLog"
        )
        // Additive (W5 increment 2). Absent in every pre-increment-2 state
        // file → `nil` → classic single-pane behavior, no schema bump.
        self.detailLayout = try container.decodeIfPresent(PaneLayoutState.self, forKey: .detailLayout)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.decodeReport = report
    }
}

public extension WorkspaceState {
    /// Newest-first cap on retained runs per entry. Every launch / recovery /
    /// auto-resume appends a new `ProcessRun`, and nothing pruned them — so a
    /// long-lived or crash-looping session accumulated runs forever, bloating
    /// the persisted state and slowing every (synchronous, main-thread) save.
    static let processRunsPerEntryCap = 25

    /// Keep only the newest `perEntryCap` runs for each entry; drop older
    /// history. Consumers always resolve "latest" via `ProcessRun.isMoreRecent`,
    /// so array order isn't load-bearing. Pure mutation (no persistence).
    mutating func pruneProcessRuns(perEntryCap: Int = WorkspaceState.processRunsPerEntryCap) {
        guard perEntryCap > 0, !processRuns.isEmpty else {
            return
        }
        var keptByEntry: [UUID: Int] = [:]
        var kept: [ProcessRun] = []
        for run in processRuns.sorted(by: ProcessRun.isMoreRecent) {
            let count = keptByEntry[run.entryId, default: 0]
            guard count < perEntryCap else {
                continue
            }
            kept.append(run)
            keptByEntry[run.entryId] = count + 1
        }
        processRuns = kept
    }

    /// One-time opt-out migration to the automate-first posture: trust every
    /// session that isn't deliberately hands-off (sessions were only untrusted
    /// because that used to be the default — never a real choice), and turn on
    /// Boss Watch so the boss is awake to act. The operator opts a session back
    /// out by marking it untrusted. Idempotent given the caller's run-once gate.
    mutating func applyAutomaticBossDefaults() {
        for index in processEntries.indices where processEntries[index].trust == .untrusted {
            processEntries[index].trust = .trusted
        }
        bossWatchEnabled = true
    }
}
