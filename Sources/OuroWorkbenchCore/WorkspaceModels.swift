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
        case lastSummary
        case notes
        case friend
        case owner
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
        lastSummary: String? = nil,
        notes: String? = nil,
        friend: SessionFriend? = nil,
        owner: SessionOwner = .human
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
        self.lastSummary = lastSummary
        self.notes = notes
        self.friend = friend
        self.owner = owner
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
        self.lastSummary = try container.decodeIfPresent(String.self, forKey: .lastSummary)
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes)
        self.friend = try container.decodeIfPresent(SessionFriend.self, forKey: .friend)
        self.owner = try container.decodeIfPresent(SessionOwner.self, forKey: .owner) ?? .human
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

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        source: String,
        action: String,
        targetEntryId: UUID? = nil,
        targetName: String? = nil,
        result: String,
        succeeded: Bool
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.source = source
        self.action = action
        self.targetEntryId = targetEntryId
        self.targetName = targetName
        self.result = result
        self.succeeded = succeeded
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

public struct WorkspaceState: Codable, Equatable, Sendable {
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
        updatedAt: Date = Date()
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
        // catch path, used to wipe the user's setup).
        var skipped = 0
        self.projects = try container.decodeLenientArray(WorkbenchProject.self, forKey: .projects, skipped: &skipped)
        self.processEntries = try container.decodeLenientArray(ProcessEntry.self, forKey: .processEntries, skipped: &skipped)
        self.processRuns = try container.decodeLenientArray(ProcessRun.self, forKey: .processRuns, skipped: &skipped)
        self.actionLog = try container.decodeLenientArray(WorkbenchActionLogEntry.self, forKey: .actionLog, skipped: &skipped)
        self.decisionLog = try container.decodeLenientArray(BossInboxDecision.self, forKey: .decisionLog, skipped: &skipped)
        // Additive (W5 increment 2). Absent in every pre-increment-2 state
        // file → `nil` → classic single-pane behavior, no schema bump.
        self.detailLayout = try container.decodeIfPresent(PaneLayoutState.self, forKey: .detailLayout)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
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
