import Foundation

public struct StartupRecoveryReconciler: Sendable {
    public init() {}

    public func reconcile(_ state: WorkspaceState, now: Date = Date()) -> WorkspaceState {
        var next = state
        for index in next.processRuns.indices {
            guard Self.requiresRecoveryAfterStartup(next.processRuns[index].status) else {
                continue
            }
            next.processRuns[index].status = .needsRecovery
            next.processRuns[index].pid = nil
            next.processRuns[index].endedAt = nil
        }

        for entryIndex in next.processEntries.indices {
            let entryId = next.processEntries[entryIndex].id
            let latestRun = next.processRuns
                .filter { $0.entryId == entryId }
                .sorted { $0.startedAt > $1.startedAt }
                .first
            if latestRun?.status == .needsRecovery {
                next.processEntries[entryIndex].attention = .needsBossReview
                next.processEntries[entryIndex].lastSummary = "\(next.processEntries[entryIndex].name) needs startup recovery"
            }
        }

        next.updatedAt = now
        return next
    }

    private static func requiresRecoveryAfterStartup(_ status: ProcessStatus) -> Bool {
        status == .running || status == .waitingForInput
    }
}
