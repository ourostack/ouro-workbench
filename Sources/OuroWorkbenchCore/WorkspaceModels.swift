import Foundation

public enum ProcessKind: String, Codable, Sendable {
    case command
    case shell
    case terminalAgent
    case ouroBoss
}

public enum ProcessTrust: String, Codable, Sendable {
    case trusted
    case untrusted
}

public enum ProcessStatus: String, Codable, Sendable {
    case configured
    case running
    case exited
    case waitingForInput
    case needsRecovery
    case manualActionNeeded
}

public enum AttentionState: String, Codable, Sendable {
    case idle
    case active
    case waitingOnHuman
    case blocked
    case needsBossReview
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

    public init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        boss: BossAgentSelection = BossAgentSelection()
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.boss = boss
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
    public var attention: AttentionState
    public var lastSummary: String?

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
        case attention
        case lastSummary
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
        trust: ProcessTrust = .untrusted,
        autoResume: Bool = false,
        attention: AttentionState = .idle,
        lastSummary: String? = nil
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
        self.attention = attention
        self.lastSummary = lastSummary
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
        self.attention = try container.decodeIfPresent(AttentionState.self, forKey: .attention) ?? .idle
        self.lastSummary = try container.decodeIfPresent(String.self, forKey: .lastSummary)
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
}

public struct WorkspaceState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var boss: BossAgentSelection
    public var projects: [WorkbenchProject]
    public var processEntries: [ProcessEntry]
    public var processRuns: [ProcessRun]
    public var updatedAt: Date

    public init(
        schemaVersion: Int = 1,
        boss: BossAgentSelection = BossAgentSelection(),
        projects: [WorkbenchProject] = [],
        processEntries: [ProcessEntry] = [],
        processRuns: [ProcessRun] = [],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.boss = boss
        self.projects = projects
        self.processEntries = processEntries
        self.processRuns = processRuns
        self.updatedAt = updatedAt
    }
}
