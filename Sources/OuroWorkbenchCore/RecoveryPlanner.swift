import Foundation

public enum RecoveryAction: String, Codable, Sendable {
    /// The persistent terminal session is still alive (the app restarted but the
    /// computer didn't) — reconnecting the viewer reattaches to the live agent
    /// with zero loss. Always safe, so it bypasses the trust / auto-resume gates
    /// that guard the side-effectful respawn path.
    case reattach
    case autoResume
    case respawn
    case manualActionNeeded
    case noAction

    /// Whether startup recovery actually *launches* something for this action.
    /// `manualActionNeeded` and `noAction` are inert (a never-run entry, an
    /// already-exited run, an untrusted respawn that needs a human, …), so they
    /// must not be treated as "this entry is being recovered" — otherwise the
    /// auto-launch-on-startup path would dedup against them and skip a fresh
    /// `autoResume` session that has no prior run.
    public var isStartupRecoveryLaunch: Bool {
        switch self {
        case .reattach, .autoResume, .respawn:
            return true
        case .manualActionNeeded, .noAction:
            return false
        }
    }
}

public struct RecoveryPlan: Codable, Equatable, Sendable {
    public var entryId: UUID
    public var runId: UUID?
    public var action: RecoveryAction
    public var reason: String

    public init(entryId: UUID, runId: UUID?, action: RecoveryAction, reason: String) {
        self.entryId = entryId
        self.runId = runId
        self.action = action
        self.reason = reason
    }
}

public struct RecoveryPlanner: Sendable {
    public init() {}

    /// `liveSessionNames` is the set of `PersistentTerminalSession` names that
    /// `screen` reports as still alive (Attached/Detached). When an entry's
    /// session is in this set, recovery becomes a lossless reattach instead of a
    /// respawn. Defaults to empty (e.g. the recovery *drill*, which simulates a
    /// full computer restart where nothing is alive).
    public func planRecovery(for state: WorkspaceState, liveSessionNames: Set<String> = []) -> [RecoveryPlan] {
        state.processEntries.map { entry in
            let latestRun = state.processRuns
                .filter { $0.entryId == entry.id }
                .sorted(by: ProcessRun.isMoreRecent)
                .first
            return planRecovery(for: entry, latestRun: latestRun, liveSessionNames: liveSessionNames)
        }
    }

    /// The set of entry ids that startup *recovery* will actually launch
    /// (reattach / auto-resume / respawn). The auto-launch-on-startup path
    /// dedups against this so it doesn't double-launch a session recovery is
    /// already handling — but it must exclude the inert `.noAction` /
    /// `.manualActionNeeded` plans (recovery emits one plan per entry,
    /// including no-ops), or the dedup set would be *every* entry and a fresh
    /// `autoResume` session with no prior run would never launch.
    public static func startupRecoveryHandledEntryIDs(_ plans: [RecoveryPlan]) -> Set<UUID> {
        Set(plans.filter { $0.action.isStartupRecoveryLaunch }.map(\.entryId))
    }

    /// Which `autoResume` entries the "auto-launch resumable terminals on
    /// startup" preference should launch: every non-archived shell / terminal
    /// agent that isn't already running and isn't being handled by startup
    /// recovery. Pure (entries + plans + active ids → eligible entries) so the
    /// dedup logic is unit-testable without the live app.
    public static func autoLaunchEligibleEntries(
        entries: [ProcessEntry],
        recoveryPlans: [RecoveryPlan],
        activeEntryIDs: Set<UUID>
    ) -> [ProcessEntry] {
        let handled = startupRecoveryHandledEntryIDs(recoveryPlans)
        return entries.filter { entry in
            entry.autoResume
                && !entry.isArchived
                && (entry.kind == .terminalAgent || entry.kind == .shell)
                && !activeEntryIDs.contains(entry.id)
                && !handled.contains(entry.id)
        }
    }

    public func planRecovery(
        for entry: ProcessEntry,
        latestRun: ProcessRun?,
        liveSessionNames: Set<String> = []
    ) -> RecoveryPlan {
        planRecovery(
            for: entry,
            latestRun: latestRun,
            liveSessionNames: liveSessionNames,
            presetFor: TerminalAgentPresets.preset(for:)
        )
    }

    func planRecovery(
        for entry: ProcessEntry,
        latestRun: ProcessRun?,
        liveSessionNames: Set<String> = [],
        presetFor: (TerminalAgentKind) -> TerminalAgentPreset?
    ) -> RecoveryPlan {
        guard !entry.isArchived else {
            return RecoveryPlan(
                entryId: entry.id,
                runId: latestRun?.id,
                action: .noAction,
                reason: "entry is archived"
            )
        }

        guard let latestRun else {
            return RecoveryPlan(
                entryId: entry.id,
                runId: nil,
                action: .noAction,
                reason: "no prior run to recover"
            )
        }

        guard latestRun.status == .needsRecovery else {
            if latestRun.status == .manualActionNeeded {
                return RecoveryPlan(
                    entryId: entry.id,
                    runId: latestRun.id,
                    action: .manualActionNeeded,
                    reason: "latest run already requires manual action"
                )
            }
            return RecoveryPlan(
                entryId: entry.id,
                runId: latestRun.id,
                action: .noAction,
                reason: "latest run status is \(latestRun.status.rawValue)"
            )
        }

        // The persistent terminal session is still alive — the app restarted but
        // the agent kept running under `screen`. Reattaching reconnects the
        // viewer losslessly, so it's always safe and bypasses the trust /
        // auto-resume gates that only the side-effectful respawn path needs.
        if liveSessionNames.contains(PersistentTerminalSession.sessionName(for: entry.id)) {
            return RecoveryPlan(
                entryId: entry.id,
                runId: latestRun.id,
                action: .reattach,
                reason: "session still running — reconnect the terminal"
            )
        }

        guard entry.trust == .trusted else {
            return RecoveryPlan(
                entryId: entry.id,
                runId: latestRun.id,
                action: .manualActionNeeded,
                reason: "entry is not trusted"
            )
        }

        guard entry.autoResume else {
            return RecoveryPlan(
                entryId: entry.id,
                runId: latestRun.id,
                action: .noAction,
                reason: "auto-resume is disabled"
            )
        }

        if entry.kind == .terminalAgent, let agentKind = TerminalAgentDetector.detect(entry: entry) {
            guard let preset = presetFor(agentKind) else {
                return RecoveryPlan(
                    entryId: entry.id,
                    runId: latestRun.id,
                    action: .respawn,
                    reason: "custom terminal agent will reopen from persisted checkpoint context"
                )
            }

            switch preset.resumeStrategy.kind {
            case .nativeResumeCommand:
                if latestRun.terminalSessionId?.isEmpty == false {
                    return RecoveryPlan(
                        entryId: entry.id,
                        runId: latestRun.id,
                        action: .autoResume,
                        reason: "\(preset.displayName) has native resume metadata"
                    )
                }
                if !preset.resumeStrategy.fallbackCommandTemplate.isEmpty {
                    return RecoveryPlan(
                        entryId: entry.id,
                        runId: latestRun.id,
                        action: .autoResume,
                        reason: "\(preset.displayName) can continue the most recent session in this working directory"
                    )
                }
                return RecoveryPlan(
                    entryId: entry.id,
                    runId: latestRun.id,
                    action: .manualActionNeeded,
                    reason: "\(preset.displayName) lacks a persisted session id"
                )
            case .checkpointPrompt:
                return RecoveryPlan(
                    entryId: entry.id,
                    runId: latestRun.id,
                    action: .respawn,
                    reason: "\(preset.displayName) will reopen from persisted checkpoint context"
                )
            case .manual:
                return RecoveryPlan(
                    entryId: entry.id,
                    runId: latestRun.id,
                    action: .manualActionNeeded,
                    reason: "\(preset.displayName) requires manual recovery"
                )
            }
        }

        return RecoveryPlan(
            entryId: entry.id,
            runId: latestRun.id,
            action: .respawn,
            reason: "trusted non-agent process may be respawned by policy"
        )
    }
}
