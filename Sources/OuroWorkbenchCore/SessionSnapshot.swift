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
    ///   - includeArchived: when false (default), archived sessions are omitted.
    public func snapshots(
        state: WorkspaceState,
        owner: String? = nil,
        name: String? = nil,
        includeArchived: Bool = false
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

            let latest = runsByEntry[entry.id]?.sorted(by: ProcessRun.isMoreRecent).first
            let ownerSnapshot: SessionOwnerSnapshot
            switch entry.owner {
            case .human:
                ownerSnapshot = SessionOwnerSnapshot(kind: "human")
            case let .agent(agentName):
                ownerSnapshot = SessionOwnerSnapshot(kind: "agent", name: agentName)
            }

            return SessionSnapshot(
                id: entry.id.uuidString,
                name: entry.name,
                group: groupNamesById[entry.projectId],
                owner: ownerSnapshot,
                kind: entry.kind.rawValue,
                status: (latest?.status ?? .configured).rawValue,
                attention: entry.attention.rawValue,
                needsHuman: entry.attention.needsHuman,
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
