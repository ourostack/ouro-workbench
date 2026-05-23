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
                    .sorted { $0.startedAt > $1.startedAt }
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
