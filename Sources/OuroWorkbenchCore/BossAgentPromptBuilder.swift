import Foundation

public struct BossAgentPromptBuilder: Sendable {
    public init() {}

    public func checkInPrompt(
        question: String,
        state: WorkspaceState,
        summary: WorkspaceSummary,
        dashboard: BossDashboardSnapshot? = nil,
        executableHealth: [UUID: ExecutableHealth] = [:],
        gitStatus: [UUID: GitSessionStatus] = [:],
        machineFriend: SessionFriend? = nil,
        waitingPrompts: [UUID: String] = [:],
        ouroAgents: [OuroAgentRecord] = [],
        recentChanges: [WorkspaceChangeSummary] = []
    ) -> String {
        var lines: [String] = []
        lines.append("You are the selected Ouro boss agent for Ouro Workbench.")
        lines.append("Workbench should appear to you as a local machine sense: a living view of terminal/TUI agents, transcripts, recovery state, and auditable native controls.")
        lines.append("Boss agent: \(summary.boss.agentName)")
        lines.append("Question: \(question)")
        lines.append("")
        lines.append("Your job: answer what is going on, identify whether anything is waiting on the human, and keep trusted work moving when the next action is clear.")
        lines.append("You may recommend or take only auditable Workbench actions: inspect output, send input, start, stop, restart, resume, respawn, create groups/terminals, move stopped sessions, update trust/restart posture, archive/restore sessions, or report status.")
        lines.append("Available Workbench tools from your Ouro runtime should include \(WorkbenchGuide.bossTools.map(\.tool).joined(separator: ", ")) when Workbench MCP is registered.")
        lines.append("When you want the native app to act now, include exactly one fenced JSON block labeled ouro-workbench-actions. Supported action values: \(WorkbenchGuide.actionVerbs.joined(separator: ", ")). Use the process id from Processes in the entry field for entry-scoped actions; names are accepted only when unique. Example:")
        lines.append("```ouro-workbench-actions")
        lines.append("[{\"action\":\"recover\",\"entry\":\"PROCESS-ID\"},{\"action\":\"sendInput\",\"entry\":\"PROCESS-ID\",\"text\":\"continue\",\"appendNewline\":true}]")
        lines.append("```")
        lines.append("")
        lines.append("For every session that is waiting on the human, record an auditable decision in exactly one fenced JSON block labeled ouro-workbench-decisions. This is the decision log for tuning — recording does NOT act yet. Decide using that session's friend (shown per process) and what you know of that friend's preferences/notes: \(BossDecisionKind.allCases.map(\.rawValue).joined(separator: ", ")). Choose autoAdvance only when the friend's preference clearly covers this prompt and it is not destructive or secret-bearing; otherwise escalate (or hold if there is nothing to do yet). Always include your reasoning and the preference you relied on. Use the process id in entry. Example:")
        lines.append("```ouro-workbench-decisions")
        lines.append("[{\"entry\":\"PROCESS-ID\",\"kind\":\"autoAdvance\",\"proposedInput\":\"1\",\"preferenceCited\":\"Ari: approve test runs\",\"confidence\":0.9,\"reasoning\":\"prompt is a test-run approval; friend pre-approves these\",\"prompt\":\"Run tests? (y/N)\"}]")
        lines.append("```")
        lines.append("")
        lines.append("Workspace status: \(summary.oneLineStatus)")
        lines.append("Boss Watch: \(state.bossWatchEnabled ? "enabled" : "paused")")
        lines.append("Boss Pane: \(state.bossPaneCollapsed ? "collapsed" : "expanded")")
        lines.append("Selected group: \(selectedProjectName(in: state))")
        if !ouroAgents.isEmpty {
            lines.append("")
            lines.append("Local Ouro agents:")
            for agent in ouroAgents.prefix(12) {
                let selected = agent.name.caseInsensitiveCompare(summary.boss.agentName) == .orderedSame
                lines.append("- \(agent.name): selected_boss=\(selected), status=\(agent.status.rawValue), bundle=\(agent.bundlePath), config=\(agent.configPath), summary=\(agent.summaryLine)")
            }
        }
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
        if !recentChanges.isEmpty {
            lines.append("Recent workspace changes:")
            for change in recentChanges.prefix(10) {
                lines.append("- \(change.occurredAt.ISO8601Format()): \(change.title) - \(change.detail)")
            }
            lines.append("")
        }
        lines.append("")
        lines.append("Organization:")
        for project in state.projects {
            let marker = project.id == state.selectedProjectId ? "*" : "-"
            let entries = state.processEntries
                .filter { $0.projectId == project.id && !$0.isArchived }
                .map(\.name)
                .joined(separator: ", ")
            lines.append("\(marker) \(project.name) (id=\(project.id.uuidString), root=\(project.rootPath)): \(entries.isEmpty ? "no active terminals" : entries)")
        }
        lines.append("")
        lines.append("Processes:")
        for snapshot in summary.processSnapshots {
            let entry = state.processEntries.first { $0.id == snapshot.id }
            let trust = entry?.trust.rawValue ?? "unknown"
            let groupName = entry.flatMap { processEntry in
                state.projects.first { $0.id == processEntry.projectId }?.name
            } ?? "unknown"
            let agentKind = TerminalAgentDetector.displayName(for: entry.flatMap(TerminalAgentDetector.detect)) ?? "generic"
            let latestRun = state.processRuns
                .filter { $0.entryId == snapshot.id }
                .sorted(by: ProcessRun.isMoreRecent)
                .first
            let transcriptPath = latestRun?.transcriptPath ?? "none"
            let health = executableHealth[snapshot.id]
            let executableStatus = health?.status.rawValue ?? "unknown"
            let executablePath = health?.resolvedPath ?? "none"
            let archived = entry?.isArchived ?? false
            let notes = entry?.trimmedNotes.map(Self.oneLine) ?? "none"
            let git = Self.gitDescription(gitStatus[snapshot.id])
            let friend = entry.flatMap { state.effectiveFriend(for: $0, fallback: machineFriend) }
                .map { "\($0.name) (\($0.kind.rawValue), \($0.trust.rawValue))" } ?? "unassigned"
            lines.append("- \(snapshot.name) (id=\(snapshot.id.uuidString)): group=\(groupName), cli=\(agentKind), friend=\(friend), archived=\(archived), trust=\(trust), executable_health=\(executableStatus), executable_path=\(executablePath), git=\(git), status=\(snapshot.status.rawValue), attention=\(snapshot.attention.rawValue), transcript=\(transcriptPath), notes=\(notes), summary=\(snapshot.summary)")
        }
        // Inline the actual waiting prompt text for sessions that need a human,
        // so you can decide (and propose the exact input) without first calling
        // workbench_transcript_tail on each one.
        let waiting = summary.processSnapshots.filter { waitingPrompts[$0.id] != nil }
        if !waiting.isEmpty {
            lines.append("")
            lines.append("Waiting prompts (decide each via ouro-workbench-decisions):")
            for snapshot in waiting {
                let snippet = Self.oneLine(waitingPrompts[snapshot.id] ?? "")
                lines.append("- \(snapshot.name) (id=\(snapshot.id.uuidString)): \(snippet)")
            }
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

    /// A thin check-in trigger: the boss fetches live state through its
    /// registered Workbench MCP tools (workbench_status etc.) rather than
    /// receiving a ~174-line embed. Keeps the action/decision protocol and a
    /// one-line pulse (so a boss that skips its tools still reports + escalates
    /// rather than going blind), but drops the per-session state dump — which
    /// is what triggered intermittent empty replies and violated the
    /// harness/Workbench boundary.
    public func checkInTrigger(question: String, summary: WorkspaceSummary) -> String {
        var lines: [String] = []
        lines.append("You are the selected Ouro boss agent for Ouro Workbench.")
        lines.append("Workbench is your local machine sense: a living view of terminal/TUI agents, transcripts, recovery state, and auditable native controls.")
        lines.append("Boss agent: \(summary.boss.agentName)")
        lines.append("Question: \(question)")
        lines.append("")
        lines.append("Your live Workbench state is NOT inlined here — fetch it through your registered Workbench MCP tools:")
        for tool in WorkbenchGuide.bossTools {
            lines.append("- \(tool.tool): \(tool.summary)")
        }
        lines.append("Start by calling workbench_status for the full per-session view (process ids, waiting prompts, git, recovery, recent action log); use workbench_sense for a quick pulse and the transcript tools to dig into a specific session.")
        lines.append("")
        lines.append("Take auditable actions with the workbench_request_action tool (use the process id from workbench_status in its `entry` argument). Supported actions: \(WorkbenchGuide.actionVerbs.joined(separator: ", ")). You may instead return exactly one fenced JSON block labeled ouro-workbench-actions with the same fields; both paths are honored.")
        lines.append("")
        lines.append("For every session waiting on a human, record an auditable decision in exactly one fenced JSON block labeled ouro-workbench-decisions (recording does NOT act yet — it is the tuning log). Decide using that session's friend and preferences: \(BossDecisionKind.allCases.map(\.rawValue).joined(separator: ", ")). Choose autoAdvance only when the friend's preference clearly covers this prompt and it is not destructive or secret-bearing; otherwise escalate (or hold). Always include reasoning and the preference relied on. Example:")
        lines.append("```ouro-workbench-decisions")
        lines.append("[{\"entry\":\"PROCESS-ID\",\"kind\":\"autoAdvance\",\"proposedInput\":\"1\",\"preferenceCited\":\"Ari: approve test runs\",\"confidence\":0.9,\"reasoning\":\"prompt is a test-run approval; friend pre-approves these\",\"prompt\":\"Run tests? (y/N)\"}]")
        lines.append("```")
        lines.append("")
        lines.append("Current pulse (call workbench_status for detail): \(summary.oneLineStatus)")
        lines.append("Then reply with a concise summary of what is going on, what is waiting on Ari, and what you did.")
        return lines.joined(separator: "\n")
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }

    /// Compact git descriptor for a process line, e.g. `main (dirty, +2/-1)`,
    /// `main (clean)`, or `none` when the working directory isn't a repo.
    private static func gitDescription(_ status: GitSessionStatus?) -> String {
        guard let status, status.isRepo, let branch = status.branchLabel else {
            return "none"
        }
        var flags = [status.dirty ? "dirty" : "clean"]
        if status.ahead > 0 || status.behind > 0 {
            flags.append("+\(status.ahead)/-\(status.behind)")
        }
        return "\(branch) (\(flags.joined(separator: ", ")))"
    }

    private func selectedProjectName(in state: WorkspaceState) -> String {
        guard let selectedProjectId = state.selectedProjectId,
              let project = state.projects.first(where: { $0.id == selectedProjectId }) else {
            return state.projects.first?.name ?? "none"
        }
        return project.name
    }
}
