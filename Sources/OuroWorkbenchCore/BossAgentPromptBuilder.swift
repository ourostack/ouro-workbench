import Foundation

public struct BossAgentPromptBuilder: Sendable {
    public init() {}

    public func checkInPrompt(
        question: String,
        state: WorkspaceState,
        summary: WorkspaceSummary,
        dashboard: BossDashboardSnapshot? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("You are the selected Ouro boss agent for Ouro Workbench.")
        lines.append("Boss agent: \(summary.boss.agentName)")
        lines.append("Question: \(question)")
        lines.append("")
        lines.append("Your job: answer what is going on, identify whether anything is waiting on the human, and keep trusted work moving when the next action is clear.")
        lines.append("You may recommend or take only auditable Workbench actions: inspect output, send input, start, stop, restart, resume, respawn, update todo/scratchpad/timer/lock state, or report status.")
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
            lines.append("- \(snapshot.name): status=\(snapshot.status.rawValue), attention=\(snapshot.attention.rawValue), summary=\(snapshot.summary)")
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
        return lines.joined(separator: "\n")
    }
}
