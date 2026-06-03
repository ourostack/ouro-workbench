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

    public init(agentName: String = "slugger", scope: String = "machine") {
        self.agentName = agentName
        self.scope = scope
    }
}

public struct WorkbenchProject: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var rootPath: String
    public var boss: BossAgentSelection
    public var deskTrackSlug: String?
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
        deskTrackSlug: String? = nil,
        colorTag: String? = nil,
        defaultFriend: SessionFriend? = nil
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.boss = boss
        self.deskTrackSlug = deskTrackSlug
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
    private enum Kind: String, Codable { case human, agent }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .human: self = .human
        case .agent: self = .agent(name: try c.decode(String.self, forKey: .name))
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
    public var deskTaskSlug: String?
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
        case deskTaskSlug
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
        deskTaskSlug: String? = nil,
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
        self.deskTaskSlug = deskTaskSlug
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
        self.deskTaskSlug = try container.decodeIfPresent(String.self, forKey: .deskTaskSlug)
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
