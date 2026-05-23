import Foundation

public enum RecoveryAction: String, Codable, Sendable {
    case autoResume
    case respawn
    case manualActionNeeded
    case noAction
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

    public func planRecovery(for state: WorkspaceState) -> [RecoveryPlan] {
        state.processEntries.map { entry in
            let latestRun = state.processRuns
                .filter { $0.entryId == entry.id }
                .sorted { $0.startedAt > $1.startedAt }
                .first
            return planRecovery(for: entry, latestRun: latestRun)
        }
    }

    public func planRecovery(for entry: ProcessEntry, latestRun: ProcessRun?) -> RecoveryPlan {
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

        if entry.kind == .terminalAgent, let agentKind = entry.agentKind {
            guard let preset = TerminalAgentPresets.preset(for: agentKind) else {
                return RecoveryPlan(
                    entryId: entry.id,
                    runId: latestRun.id,
                    action: .manualActionNeeded,
                    reason: "unknown terminal agent preset"
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
