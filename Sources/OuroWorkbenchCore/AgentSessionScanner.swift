import Foundation

/// The agent harness that produced a discovered session. GENERAL by design —
/// it names only the harness binary family, never an agent identity, a repo, or
/// any MS/agency-specific knowledge. Mirrors `TerminalAgentKind` (and decodes
/// unknown raw values to `.custom` the same way) so a record can flow into a
/// `ProcessEntry`/`CustomTerminalSessionDraft` without a lossy remap.
public enum AgentHarness: String, Codable, CaseIterable, Sendable {
    case claudeCode
    case githubCopilotCLI
    case openAICodex
    case custom

    /// Unknown raw values (a harness added by a newer build, or a future Codable
    /// of an extended enum) decode to `.custom` rather than throwing — a record
    /// from a newer producer is still usable, just defaulted.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentHarness(rawValue: raw) ?? .custom
    }
}

/// A GENERAL record of a discovered agent session. Zero command-building, zero
/// agency knowledge: it states only what was observed on disk or in the process
/// table. The boss agent — not Workbench — turns these facts into resume
/// commands. Fields are exactly the discovery surface the spec locked:
/// `harness, sessionId, cwd, repository, branch, title, lastActive, running`.
public struct AgentSessionRecord: Codable, Equatable, Sendable {
    public var harness: AgentHarness
    public var sessionId: String
    public var cwd: String
    public var repository: String?
    public var branch: String?
    public var title: String?
    public var lastActive: Date?
    public var running: Bool

    /// Stable identity: harness + sessionId. Two scans of the same session
    /// produce the same `id`, which is what dedup keys on.
    public var id: String { "\(harness.rawValue):\(sessionId)" }

    public init(
        harness: AgentHarness,
        sessionId: String,
        cwd: String,
        repository: String? = nil,
        branch: String? = nil,
        title: String? = nil,
        lastActive: Date? = nil,
        running: Bool
    ) {
        self.harness = harness
        self.sessionId = sessionId
        self.cwd = cwd
        self.repository = repository
        self.branch = branch
        self.title = title
        self.lastActive = lastActive
        self.running = running
    }

    private enum CodingKeys: String, CodingKey {
        case harness
        case sessionId
        case cwd
        case repository
        case branch
        case title
        case lastActive
        case running
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.harness = try container.decode(AgentHarness.self, forKey: .harness)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.cwd = try container.decode(String.self, forKey: .cwd)
        self.repository = try container.decodeIfPresent(String.self, forKey: .repository)
        self.branch = try container.decodeIfPresent(String.self, forKey: .branch)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.lastActive = try container.decodeIfPresent(Date.self, forKey: .lastActive)
        self.running = try container.decode(Bool.self, forKey: .running)
    }
}
