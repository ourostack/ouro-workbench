import Foundation

public struct BossAgentPromptBuilder: Sendable {
    public init() {}

    public func checkInPrompt(
        question: String,
        state: WorkspaceState,
        summary: WorkspaceSummary,
        dashboard: BossDashboardSnapshot? = nil,
        executableHealth: [UUID: ExecutableHealth] = [:]
    ) -> String {
        var lines: [String] = []
        lines.append("You are the selected Ouro boss agent for Ouro Workbench.")
        lines.append("Boss agent: \(summary.boss.agentName)")
        lines.append("Question: \(question)")
        lines.append("")
        lines.append("Your job: answer what is going on, identify whether anything is waiting on the human, and keep trusted work moving when the next action is clear.")
        lines.append("You may recommend or take only auditable Workbench actions: inspect output, send input, start, stop, restart, resume, respawn, update todo/scratchpad/timer/lock state, or report status.")
        lines.append("When you want the native app to act now, include exactly one fenced JSON block labeled ouro-workbench-actions. Supported action values: launch, recover, terminate, sendInput. Use the process id from Processes in the entry field; names are accepted only when unique. Example:")
        lines.append("```ouro-workbench-actions")
        lines.append("[{\"action\":\"recover\",\"entry\":\"PROCESS-ID\"},{\"action\":\"sendInput\",\"entry\":\"PROCESS-ID\",\"text\":\"continue\",\"appendNewline\":true}]")
        lines.append("```")
        lines.append("")
        lines.append("Workspace status: \(summary.oneLineStatus)")
        if let dashboard {
            if !dashboard.availability.issues.isEmpty {
                lines.append("Mailbox warnings: \(dashboard.availability.issues.joined(separator: "; "))")
            }
            let needsMeCount = dashboard.availability.needsMeAvailable ? String(dashboard.needsMeItems.count) : "unknown"
            let activeCodingCount = dashboard.availability.codingAvailable ? String(dashboard.activeCodingAgents) : "unknown"
            let blockedCodingCount = dashboard.availability.codingAvailable ? String(dashboard.blockedCodingAgents) : "unknown"
            lines.append("Mailbox status: daemon=\(dashboard.daemonStatus), attention=\(dashboard.attentionLabel), needs_me=\(needsMeCount), active_coding=\(activeCodingCount), blocked_coding=\(blockedCodingCount)")
            if !dashboard.needsMeItems.isEmpty {
                lines.append("")
                lines.append("Needs me:")
                for item in dashboard.needsMeItems.prefix(8) {
                    lines.append("- \(item.urgency): \(item.label) - \(item.detail)")
                }
            }
            if !dashboard.codingItems.isEmpty {
                lines.append("")
                lines.append("Mailbox coding sessions:")
                for item in dashboard.codingItems.prefix(8) {
                    lines.append("- \(item.runner) \(item.id): status=\(item.status), workdir=\(item.workdir), checkpoint=\(item.checkpoint ?? "none")")
                }
            }
        }
        lines.append("")
        lines.append("Processes:")
        for snapshot in summary.processSnapshots {
            let entry = state.processEntries.first { $0.id == snapshot.id }
            let trust = entry?.trust.rawValue ?? "unknown"
            let latestRun = state.processRuns
                .filter { $0.entryId == snapshot.id }
                .sorted { $0.startedAt > $1.startedAt }
                .first
            let transcriptPath = latestRun?.transcriptPath ?? "none"
            let health = executableHealth[snapshot.id]
            let executableStatus = health?.status.rawValue ?? "unknown"
            let executablePath = health?.resolvedPath ?? "none"
            let archived = entry?.isArchived ?? false
            lines.append("- \(snapshot.name) (id=\(snapshot.id.uuidString)): archived=\(archived), trust=\(trust), executable_health=\(executableStatus), executable_path=\(executablePath), status=\(snapshot.status.rawValue), attention=\(snapshot.attention.rawValue), transcript=\(transcriptPath), summary=\(snapshot.summary)")
        }
        lines.append("")
        lines.append("Recovery:")
        if summary.recoveryPlans.isEmpty {
            lines.append("- no configured recovery plans")
        } else {
            for plan in summary.recoveryPlans {
                let entryName = state.processEntries.first { $0.id == plan.entryId }?.name ?? plan.entryId.uuidString
                lines.append("- \(entryName): action=\(plan.action.rawValue), reason=\(plan.reason)")
            }
        }
        if !state.actionLog.isEmpty {
            lines.append("")
            lines.append("Recent action log:")
            for entry in state.actionLog.sorted(by: { $0.occurredAt > $1.occurredAt }).prefix(8) {
                let outcome = entry.succeeded ? "ok" : "skipped"
                let target = entry.targetName ?? "none"
                lines.append("- \(entry.occurredAt.ISO8601Format()): \(outcome), source=\(entry.source), action=\(entry.action), target=\(target), result=\(entry.result)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
