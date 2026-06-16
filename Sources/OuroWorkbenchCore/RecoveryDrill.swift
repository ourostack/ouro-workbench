import Foundation

public struct RecoveryDrillItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var entryName: String
    public var beforeStatus: ProcessStatus?
    public var afterStatus: ProcessStatus?
    public var action: RecoveryAction
    public var reason: String

    public init(
        id: UUID,
        entryName: String,
        beforeStatus: ProcessStatus?,
        afterStatus: ProcessStatus?,
        action: RecoveryAction,
        reason: String
    ) {
        self.id = id
        self.entryName = entryName
        self.beforeStatus = beforeStatus
        self.afterStatus = afterStatus
        self.action = action
        self.reason = reason
    }
}

public struct RecoveryDrillResult: Codable, Equatable, Sendable {
    public var ranAt: Date
    public var oneLineStatus: String
    public var items: [RecoveryDrillItem]

    public init(ranAt: Date, oneLineStatus: String, items: [RecoveryDrillItem]) {
        self.ranAt = ranAt
        self.oneLineStatus = oneLineStatus
        self.items = items
    }
}

public struct RecoveryDrill: Sendable {
    private let reconciler: StartupRecoveryReconciler
    private let planRecovery: @Sendable (WorkspaceState) -> [RecoveryPlan]

    public init(
        reconciler: StartupRecoveryReconciler = StartupRecoveryReconciler(),
        recoveryPlanner: RecoveryPlanner = RecoveryPlanner(),
        planRecovery: (@Sendable (WorkspaceState) -> [RecoveryPlan])? = nil
    ) {
        self.reconciler = reconciler
        self.planRecovery = planRecovery ?? { recoveryPlanner.planRecovery(for: $0) }
    }

    public func run(state: WorkspaceState, now: Date = Date()) -> RecoveryDrillResult {
        let simulated = reconciler.reconcile(state, now: now)
        let beforeRuns = latestRunsByEntry(in: state)
        let afterRuns = latestRunsByEntry(in: simulated)
        let plans = Dictionary(uniqueKeysWithValues: planRecovery(simulated).map { ($0.entryId, $0) })
        let items = simulated.processEntries.map { entry in
            let plan = plans[entry.id] ?? RecoveryPlan(
                entryId: entry.id,
                runId: afterRuns[entry.id]?.id,
                action: .noAction,
                reason: "no recovery plan"
            )
            return RecoveryDrillItem(
                id: entry.id,
                entryName: entry.name,
                beforeStatus: beforeRuns[entry.id]?.status,
                afterStatus: afterRuns[entry.id]?.status,
                action: plan.action,
                reason: plan.reason
            )
        }
        let actionableCount = items.filter { item in
            item.action == .autoResume || item.action == .respawn || item.action == .manualActionNeeded
        }.count
        let oneLineStatus = "\(actionableCount) recovery action\(actionableCount == 1 ? "" : "s") after simulated restart"
        return RecoveryDrillResult(ranAt: now, oneLineStatus: oneLineStatus, items: items)
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
