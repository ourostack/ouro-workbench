import Foundation

public struct BossAgentPromptBuilder: Sendable {
    public init() {}

    public func checkInPrompt(question: String, state: WorkspaceState, summary: WorkspaceSummary) -> String {
        var lines: [String] = []
        lines.append("You are the selected Ouro boss agent for Ouro Workbench.")
        lines.append("Boss agent: \(summary.boss.agentName)")
        lines.append("Question: \(question)")
        lines.append("")
        lines.append("Your job: answer what is going on, identify whether anything is waiting on the human, and keep trusted work moving when the next action is clear.")
        lines.append("You may recommend or take only auditable Workbench actions: inspect output, send input, start, stop, restart, resume, respawn, update todo/scratchpad/timer/lock state, or report status.")
        lines.append("")
        lines.append("Workspace status: \(summary.oneLineStatus)")
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
