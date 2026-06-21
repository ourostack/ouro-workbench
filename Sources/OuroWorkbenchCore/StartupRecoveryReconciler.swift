import Foundation

public struct StartupRecoveryReconciler: Sendable {
    private let recoveryPlanner: RecoveryPlanner

    public init(recoveryPlanner: RecoveryPlanner = RecoveryPlanner()) {
        self.recoveryPlanner = recoveryPlanner
    }

    /// Reclassify in-flight runs as needing recovery on startup, then assign each
    /// recovering entry an HONEST attention state (U8a).
    ///
    /// `liveSessionNames` is the set of `screen` sessions still alive — the
    /// SAME signal `RecoveryPlanner` uses to decide a lossless reattach. When a
    /// recovering entry's persistent session is in this set, it kept running
    /// while Workbench was closed (the success case of reboot recovery): it
    /// lands calm (`.idle`, never `.needsBossReview`, so it stays OUT of the
    /// boss's waiting-on-you bucket) with a "reconnected" summary. The async
    /// reattach then reconnects the viewer and flips it `.active`.
    ///
    /// Only GENUINELY-lost sessions get an attention flag, and that flag
    /// distinguishes "auto-resuming" (a recoverable plan exists → calm `.idle`)
    /// from "needs you" (manual action → `.needsBossReview`, which the boss
    /// reads as waiting-on-you).
    ///
    /// The default empty `liveSessionNames` is the safe degrade used by the
    /// synchronous load path before the `screen -ls` probe completes: nothing is
    /// known-alive yet, so everything is treated as lost. The App re-runs this
    /// once the probe populates the live set (see
    /// `reconcileStartupAttentionWithLiveSessions`).
    public func reconcile(
        _ state: WorkspaceState,
        liveSessionNames: Set<String> = [],
        now: Date = Date()
    ) -> WorkspaceState {
        var next = state
        for index in next.processRuns.indices {
            guard Self.requiresRecoveryAfterStartup(next.processRuns[index].status) else {
                continue
            }
            next.processRuns[index].status = .needsRecovery
            next.processRuns[index].pid = nil
            next.processRuns[index].endedAt = nil
        }

        assignAttention(&next, liveSessionNames: liveSessionNames)
        next.updatedAt = now
        return next
    }

    /// Re-derive ONLY attention/summary for entries already in needs-recovery,
    /// given a now-known live-session set — WITHOUT re-touching any run (U8a).
    ///
    /// The App calls this once the `screen -ls` probe completes, so survivors
    /// flip from the load-time lost-state flag to a calm "reconnected". It
    /// deliberately skips the `.running`/`.waitingForInput` → needs-recovery
    /// reclassification `reconcile` does, so a session the operator launched
    /// fresh between load and the probe keeps its live `.running` run.
    public func rederiveAttention(
        _ state: WorkspaceState,
        liveSessionNames: Set<String>,
        now: Date = Date()
    ) -> WorkspaceState {
        var next = state
        assignAttention(&next, liveSessionNames: liveSessionNames)
        next.updatedAt = now
        return next
    }

    /// Shared attention assignment: for every entry whose latest run is
    /// needs-recovery, key its attention + summary off the recovery plan (which
    /// folds in live-session survival).
    private func assignAttention(_ next: inout WorkspaceState, liveSessionNames: Set<String>) {
        for entryIndex in next.processEntries.indices {
            let entry = next.processEntries[entryIndex]
            let latestRun = next.processRuns
                .filter { $0.entryId == entry.id }
                .sorted(by: ProcessRun.isMoreRecent)
                .first
            guard latestRun?.status == .needsRecovery else {
                continue
            }
            let plan = recoveryPlanner.planRecovery(
                for: entry,
                latestRun: latestRun,
                liveSessionNames: liveSessionNames
            )
            let (attention, summary) = Self.attention(for: plan.action, entryName: entry.name)
            next.processEntries[entryIndex].attention = attention
            next.processEntries[entryIndex].lastSummary = summary
        }
    }

    /// Honest attention + summary for a recovering entry, keyed off the recovery
    /// plan the planner produced (which already folded in live-session survival).
    /// - `.reattach`: survived — calm `.idle`, reconnected summary.
    /// - `.autoResume` / `.respawn`: lost but auto-resuming — calm `.idle`.
    /// - `.manualActionNeeded`: genuinely needs the operator — `.needsBossReview`.
    /// - `.noAction`: nothing actionable — leave it calm `.idle`.
    static func attention(
        for action: RecoveryAction,
        entryName: String
    ) -> (AttentionState, String) {
        switch action {
        case .reattach:
            return (.idle, "\(entryName) reconnected — kept running while Workbench was closed")
        case .autoResume, .respawn:
            return (.idle, "\(entryName) will auto-resume on recovery")
        case .manualActionNeeded:
            return (.needsBossReview, "\(entryName) needs you to recover")
        case .noAction:
            return (.idle, "\(entryName) is ready")
        }
    }

    private static func requiresRecoveryAfterStartup(_ status: ProcessStatus) -> Bool {
        status == .running || status == .waitingForInput
    }
}
