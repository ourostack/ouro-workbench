import Foundation

public struct ProcessSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var status: ProcessStatus
    public var attention: AttentionState
    public var latestRunId: UUID?
    public var summary: String

    public init(
        id: UUID,
        name: String,
        status: ProcessStatus,
        attention: AttentionState,
        latestRunId: UUID?,
        summary: String
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.attention = attention
        self.latestRunId = latestRunId
        self.summary = summary
    }
}

public struct WorkspaceSummary: Codable, Equatable, Sendable {
    public var boss: BossAgentSelection
    public var processSnapshots: [ProcessSnapshot]
    public var recoveryPlans: [RecoveryPlan]

    public init(
        boss: BossAgentSelection,
        processSnapshots: [ProcessSnapshot],
        recoveryPlans: [RecoveryPlan]
    ) {
        self.boss = boss
        self.processSnapshots = processSnapshots
        self.recoveryPlans = recoveryPlans
    }

    public var waitingOnHuman: [ProcessSnapshot] {
        processSnapshots.filter { snapshot in
            snapshot.status == .waitingForInput || snapshot.attention == .waitingOnHuman
        }
    }

    public var needsRecovery: [RecoveryPlan] {
        recoveryPlans.filter { plan in
            plan.action == .autoResume || plan.action == .respawn || plan.action == .manualActionNeeded
        }
    }

    public var oneLineStatus: String {
        if !waitingOnHuman.isEmpty {
            let names = waitingOnHuman.map(\.name).joined(separator: ", ")
            return "\(names) waiting on human input"
        }
        let runningCount = processSnapshots.filter { $0.status == .running }.count
        let recoveryCount = needsRecovery.count
        return "\(runningCount) running, \(recoveryCount) recovery action\(recoveryCount == 1 ? "" : "s")"
    }
}

public struct WorkspaceChangeSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var occurredAt: Date
    public var entryId: UUID?
    public var title: String
    public var detail: String

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        entryId: UUID? = nil,
        title: String,
        detail: String
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.entryId = entryId
        self.title = title
        self.detail = detail
    }
}

public struct WorkspaceChangeSummarizer: Sendable {
    public init() {}

    public func summarize(previous: WorkspaceState, current: WorkspaceState, occurredAt: Date = Date()) -> [WorkspaceChangeSummary] {
        let previousEntries = Dictionary(uniqueKeysWithValues: previous.processEntries.map { ($0.id, $0) })
        let currentEntries = Dictionary(uniqueKeysWithValues: current.processEntries.map { ($0.id, $0) })
        let previousLatestRuns = latestRunsByEntry(in: previous)
        let currentLatestRuns = latestRunsByEntry(in: current)
        let previousActionLogIDs = Set(previous.actionLog.map(\.id))

        var changes: [WorkspaceChangeSummary] = []

        for entry in current.processEntries {
            guard let previousEntry = previousEntries[entry.id] else {
                changes.append(WorkspaceChangeSummary(
                    occurredAt: occurredAt,
                    entryId: entry.id,
                    title: "Session added",
                    detail: "\(entry.name) was added to the workbench"
                ))
                continue
            }

            if previousEntry.name != entry.name {
                changes.append(WorkspaceChangeSummary(
                    occurredAt: occurredAt,
                    entryId: entry.id,
                    title: "Session renamed",
                    detail: "\(previousEntry.name) is now \(entry.name)"
                ))
            }

            if previousEntry.isArchived != entry.isArchived {
                changes.append(WorkspaceChangeSummary(
                    occurredAt: occurredAt,
                    entryId: entry.id,
                    title: entry.isArchived ? "Session archived" : "Session restored",
                    detail: "\(entry.name) is \(entry.isArchived ? "archived" : "active")"
                ))
            }

            if previousEntry.attention != entry.attention {
                changes.append(WorkspaceChangeSummary(
                    occurredAt: occurredAt,
                    entryId: entry.id,
                    title: "Attention changed",
                    detail: "\(entry.name) attention changed from \(previousEntry.attention.rawValue) to \(entry.attention.rawValue)"
                ))
            }

            let previousRun = previousLatestRuns[entry.id]
            let currentRun = currentLatestRuns[entry.id]
            if previousRun?.id != currentRun?.id, let currentRun {
                changes.append(WorkspaceChangeSummary(
                    occurredAt: occurredAt,
                    entryId: entry.id,
                    title: "Run started",
                    detail: "\(entry.name) started run \(currentRun.id.uuidString)"
                ))
            } else if previousRun?.status != currentRun?.status, let previousRun, let currentRun {
                changes.append(WorkspaceChangeSummary(
                    occurredAt: occurredAt,
                    entryId: entry.id,
                    title: "Run status changed",
                    detail: "\(entry.name) changed from \(previousRun.status.rawValue) to \(currentRun.status.rawValue)"
                ))
            }
        }

        for entry in previous.processEntries where currentEntries[entry.id] == nil {
            changes.append(WorkspaceChangeSummary(
                occurredAt: occurredAt,
                entryId: entry.id,
                title: "Session removed",
                detail: "\(entry.name) was removed from the workbench"
            ))
        }

        for action in current.actionLog where !previousActionLogIDs.contains(action.id) {
            changes.append(WorkspaceChangeSummary(
                id: action.id,
                occurredAt: action.occurredAt,
                entryId: action.targetEntryId,
                title: action.succeeded ? "Action applied" : "Action skipped",
                detail: "\(action.source) \(action.action): \(action.result)"
            ))
        }

        return changes.sorted { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt {
                return lhs.occurredAt > rhs.occurredAt
            }
            return lhs.title < rhs.title
        }
    }

    private func latestRunsByEntry(in state: WorkspaceState) -> [UUID: ProcessRun] {
        var latest: [UUID: ProcessRun] = [:]
        for run in state.processRuns {
            guard let existing = latest[run.entryId] else {
                latest[run.entryId] = run
                continue
            }
            if ProcessRun.isMoreRecent(run, existing) {
                latest[run.entryId] = run
            }
        }
        return latest
    }
}

public struct WorkspaceSummarizer: Sendable {
    private let recoveryPlanner: RecoveryPlanner

    public init(recoveryPlanner: RecoveryPlanner = RecoveryPlanner()) {
        self.recoveryPlanner = recoveryPlanner
    }

    public func summarize(_ state: WorkspaceState) -> WorkspaceSummary {
        let recoveryPlans = recoveryPlanner.planRecovery(for: state)
        return WorkspaceSummary(
            boss: state.boss,
            processSnapshots: state.processEntries.map { entry in
                let latestRun = state.processRuns
                    .filter { $0.entryId == entry.id }
                    .sorted(by: ProcessRun.isMoreRecent)
                    .first
                return ProcessSnapshot(
                    id: entry.id,
                    name: entry.name,
                    status: latestRun?.status ?? .configured,
                    attention: entry.attention,
                    latestRunId: latestRun?.id,
                    summary: entry.lastSummary ?? defaultSummary(for: entry, latestRun: latestRun)
                )
            },
            recoveryPlans: recoveryPlans
        )
    }

    private func defaultSummary(for entry: ProcessEntry, latestRun: ProcessRun?) -> String {
        if let latestRun {
            switch latestRun.status {
            case .running:
                return "\(entry.name) is running as pid \(latestRun.pid.map(String.init) ?? "unknown")"
            case .exited:
                return "\(entry.name) exited with code \(latestRun.exitCode.map(String.init) ?? "unknown")"
            case .waitingForInput:
                return "\(entry.name) is waiting for input"
            case .needsRecovery:
                return "\(entry.name) needs recovery"
            case .manualActionNeeded:
                return "\(entry.name) needs manual recovery"
            case .configured:
                return "\(entry.name) is configured"
            }
        }
        return "\(entry.name) is configured"
    }
}
