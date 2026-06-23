import XCTest
@testable import OuroWorkbenchCore

final class BossAgentPromptBuilderTests: XCTestCase {
    /// Builds a small workspace where one trusted session is waiting on a
    /// human, so `oneLineStatus` is deterministic.
    private func makeFixture() -> (state: WorkspaceState, summary: WorkspaceSummary) {
        let project = WorkbenchProject(name: "Project", rootPath: "/tmp/project")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            workingDirectory: "/tmp/project",
            trust: .trusted,
            autoResume: true,
            attention: .waitingOnHuman,
            lastSummary: "Codex wants a product decision"
        )
        let state = WorkspaceState(
            projects: [project],
            processEntries: [entry],
            processRuns: [ProcessRun(entryId: entry.id, status: .waitingForInput)]
        )
        let summary = WorkspaceSummarizer().summarize(state)
        return (state, summary)
    }

    func testCheckInTriggerCarriesProtocolAndPulse() {
        let (_, summary) = makeFixture()
        let question = "is anything waiting on me?"

        let trigger = BossAgentPromptBuilder().checkInTrigger(question: question, summary: summary)

        // Tool-grounding: points the boss at its Workbench MCP tools.
        XCTAssertTrue(trigger.contains("workbench_status"))
        // Carries the question verbatim.
        XCTAssertTrue(trigger.contains(question))
        // Keeps the auditable decision protocol.
        XCTAssertTrue(trigger.contains("ouro-workbench-decisions"))
        // Keeps a one-line pulse so a tool-skipping boss still reports/escalates.
        XCTAssertEqual(summary.oneLineStatus, "Codex waiting on human input")
        XCTAssertTrue(trigger.contains(summary.oneLineStatus))
    }

    func testCheckInTriggerWeavesInTheResolvedOwnerName() {
        // The scaffold reports on the ACTUAL operator — the owner name is injected,
        // never the hardcoded "Ari".
        let (_, summary) = makeFixture()
        let trigger = BossAgentPromptBuilder(ownerName: "Dana Lee").checkInTrigger(question: "q", summary: summary)
        XCTAssertTrue(trigger.contains("what is waiting on Dana Lee"))
        XCTAssertFalse(trigger.contains("Ari"))
    }

    func testCheckInPromptSurfacesSessionOwnerAndAgentGuidance() {
        // A workspace with both a human-owned waiting session and an
        // agent-owned (agent-driven) session.
        let project = WorkbenchProject(name: "Project", rootPath: "/tmp/project")
        let humanEntry = ProcessEntry(
            projectId: project.id,
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            workingDirectory: "/tmp/project",
            trust: .trusted,
            attention: .waitingOnHuman,
            lastSummary: "Codex wants a product decision",
            owner: .human
        )
        let agentEntry = ProcessEntry(
            projectId: project.id,
            name: "Slugger coding session",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            workingDirectory: "/tmp/project",
            trust: .trusted,
            attention: .waitingOnHuman,
            lastSummary: "Slugger is iterating on a fix",
            owner: .agent(name: "slugger")
        )
        let state = WorkspaceState(
            projects: [project],
            processEntries: [humanEntry, agentEntry],
            processRuns: [
                ProcessRun(entryId: humanEntry.id, status: .waitingForInput),
                ProcessRun(entryId: agentEntry.id, status: .waitingForInput)
            ]
        )
        let summary = WorkspaceSummarizer().summarize(state)

        // Mirrors how workbenchStatus() invokes the builder.
        let prompt = BossAgentPromptBuilder().checkInPrompt(
            question: "What is currently going on in Ouro Workbench?",
            state: state,
            summary: summary,
            executableHealth: [:],
            gitStatus: [:],
            machineFriend: SessionFriend.machineOwner(),
            waitingPrompts: [:]
        )

        // (a) The per-session listing labels each session's owner.
        XCTAssertTrue(prompt.contains("owner=agent:slugger"))
        XCTAssertTrue(prompt.contains("owner=human"))
        // (b) The decision protocol tells the boss to hold agent-owned sessions.
        XCTAssertTrue(prompt.contains("Sessions owned by an agent (owner=agent:<name>) are driven by that agent's own loop"))
    }

    func testCheckInPromptFoldsInTheOneLineAutonomyVerdictAndPointsAtTheTool() {
        // #U20: the boss sees hands-off readiness in the check-in without a second call,
        // and is pointed at workbench_autonomy_readiness to act on blockers.
        let (state, summary) = makeFixture()
        let prompt = BossAgentPromptBuilder().checkInPrompt(
            question: "q",
            state: state,
            summary: summary,
            autonomyVerdict: "To get to green, the operator needs to: Trust the agent terminals so the boss may drive them."
        )

        XCTAssertTrue(prompt.contains("Autonomy readiness: To get to green, the operator needs to: Trust the agent terminals"))
        XCTAssertTrue(prompt.contains("call workbench_autonomy_readiness"))
    }

    func testCheckInPromptOmitsTheAutonomyLineWhenNoVerdictIsSupplied() {
        // Existing callers that don't pass a verdict get the unchanged prompt — no empty line.
        let (state, summary) = makeFixture()
        let prompt = BossAgentPromptBuilder().checkInPrompt(question: "q", state: state, summary: summary)
        XCTAssertFalse(prompt.contains("Autonomy readiness:"))
    }

    func testCheckInTriggerIsSubstantiallyShorterThanFullPrompt() {
        // A non-trivial machine: the trigger carries a FIXED tool list while the
        // full prompt grows a per-session dump per session, so on a populated
        // machine the full prompt must out-weigh the thin trigger. (On a near-empty
        // machine the fixed tool list can exceed the dump — which is why this asserts
        // on a many-session state, robust to the tool catalog growing.)
        let project = WorkbenchProject(name: "Project", rootPath: "/tmp/project")
        var entries: [ProcessEntry] = []
        var runs: [ProcessRun] = []
        for index in 0..<12 {
            let entry = ProcessEntry(
                projectId: project.id,
                name: "Session-\(index)",
                kind: .terminalAgent,
                agentKind: .openAICodex,
                executable: "codex",
                workingDirectory: "/tmp/project/sub-\(index)",
                trust: .trusted,
                autoResume: true,
                attention: index.isMultiple(of: 2) ? .waitingOnHuman : .active,
                lastSummary: "Session \(index) is doing some substantial work right now"
            )
            entries.append(entry)
            runs.append(ProcessRun(entryId: entry.id, status: .waitingForInput))
        }
        let state = WorkspaceState(projects: [project], processEntries: entries, processRuns: runs)
        let summary = WorkspaceSummarizer().summarize(state)
        let question = "is anything waiting on me?"
        let builder = BossAgentPromptBuilder()

        let trigger = builder.checkInTrigger(question: question, summary: summary)
        let fullPrompt = builder.checkInPrompt(question: question, state: state, summary: summary)

        // The thin trigger drops the per-session state dump, so it must be
        // materially shorter than the full embed for a populated machine.
        XCTAssertLessThan(trigger.count, fullPrompt.count)
    }

    func testCheckInPromptRendersMailboxAgentsChangesGitRecoveryAndActionLogDetails() {
        let selectedProject = WorkbenchProject(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "Selected", rootPath: "/work/selected")
        let otherProject = WorkbenchProject(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, name: "Other", rootPath: "/work/other")
        let primary = ProcessEntry(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            projectId: selectedProject.id,
            name: "Primary",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            workingDirectory: "/work/selected",
            trust: .trusted,
            autoResume: true,
            attention: .waitingOnHuman,
            lastSummary: "Needs a choice",
            notes: "multi\nline notes",
            owner: .human
        )
        let secondary = ProcessEntry(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            projectId: otherProject.id,
            name: "Archived Agent",
            kind: .terminalAgent,
            agentKind: .custom,
            executable: "agent",
            workingDirectory: "/work/other",
            trust: .untrusted,
            isArchived: true,
            owner: .agent(name: "bot")
        )
        let run = ProcessRun(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            entryId: primary.id,
            pid: 123,
            status: .waitingForInput,
            startedAt: Date(timeIntervalSince1970: 400),
            transcriptPath: "/logs/primary.txt"
        )
        let olderRun = ProcessRun(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555556")!,
            entryId: primary.id,
            pid: 122,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 100),
            transcriptPath: "/logs/older.txt"
        )
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "Bossy"),
            bossWatchEnabled: false,
            bossPaneCollapsed: true,
            selectedProjectId: selectedProject.id,
            projects: [selectedProject, otherProject],
            processEntries: [primary, secondary],
            processRuns: [olderRun, run],
            actionLog: [
                WorkbenchActionLogEntry(
                    occurredAt: Date(timeIntervalSince1970: 200),
                    source: "boss",
                    action: "sendInput",
                    targetName: "Primary",
                    result: "sent continue",
                    succeeded: true
                ),
                WorkbenchActionLogEntry(
                    occurredAt: Date(timeIntervalSince1970: 100),
                    source: "operator",
                    action: "recover",
                    result: "not trusted",
                    succeeded: false
                )
            ]
        )
        var summary = WorkspaceSummarizer().summarize(state)
        summary.recoveryPlans = [
            RecoveryPlan(entryId: primary.id, runId: run.id, action: .autoResume, reason: "trusted auto-resume"),
            RecoveryPlan(entryId: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!, runId: nil, action: .manualActionNeeded, reason: "missing entry still reported")
        ]
        let dashboard = BossDashboardSnapshot(
            agentName: "Bossy",
            daemonStatus: "ok",
            daemonMode: "managed",
            attentionLabel: "focused",
            openObligations: 2,
            activeCodingAgents: 3,
            blockedCodingAgents: 1,
            needsMeItems: [
                MailboxNeedsMeItem(
                    urgency: "high",
                    label: "Approve deploy",
                    detail: "Production rollout?",
                    ref: MailboxNavigationRef(tab: "needs-me", focus: "deploy"),
                    ageMs: 42
                )
            ],
            codingItems: [
                MailboxCodingItem(
                    id: "coding-1",
                    runner: "codex",
                    status: "blocked",
                    workdir: "/repo",
                    lastActivityAt: "2026-01-01T00:00:00Z",
                    checkpoint: nil,
                    taskRef: "T1"
                )
            ],
            habitHistory: HabitHistoryPanelModel(summaries: [
                MailboxHabitSessionSummary(
                    runId: "habit-1",
                    habitName: "Morning check",
                    operationId: nil,
                    status: "succeeded",
                    triggeredAt: "2026-01-01T00:00:00Z",
                    completedAt: "2026-01-01T00:01:00Z",
                    summary: "line one\nline two",
                    decisions: [],
                    pending: MailboxHabitSummaryPending(count: 0, files: []),
                    messagesSent: [],
                    toolsUsed: [],
                    producedRefs: [],
                    errors: [],
                    warnings: [],
                    nextLikelyStep: nil,
                    sources: MailboxHabitSummarySources(
                        receipt: "receipt.json",
                        session: "session.json",
                        pending: "pending.json",
                        runtimeState: "state.json"
                    )
                )
            ]),
            observedAt: "2026-01-01T00:02:00Z",
            availability: .mailbox(
                machineIssue: "machine: offline",
                needsMeIssue: nil,
                codingIssue: nil,
                habitHistoryIssue: nil
            ),
            knownAgentNames: ["Bossy"]
        )

        let prompt = BossAgentPromptBuilder(ownerName: "Dana").checkInPrompt(
            question: "status?",
            state: state,
            summary: summary,
            dashboard: dashboard,
            executableHealth: [
                primary.id: ExecutableHealth(executable: "codex", resolvedPath: "/usr/bin/codex", status: .available, detail: "ok")
            ],
            gitStatus: [
                primary.id: GitSessionStatus(isRepo: true, branch: "feature", dirty: true, ahead: 2, behind: 1)
            ],
            machineFriend: SessionFriend(name: "Dana", kind: .human, trust: .friend),
            waitingPrompts: [primary.id: "Proceed?\n1) yes"],
            ouroAgents: [
                OuroAgentRecord(
                    name: "Bossy",
                    bundlePath: "/agents/bossy",
                    configPath: "/agents/bossy/config",
                    status: .ready,
                    detail: "ready",
                    humanFacing: OuroAgentLane(provider: "openai", model: "gpt"),
                    agentFacing: OuroAgentLane(provider: "anthropic", model: "sonnet")
                )
            ],
            recentChanges: [
                WorkspaceChangeSummary(occurredAt: Date(timeIntervalSince1970: 300), entryId: primary.id, title: "Transcript updated", detail: "Primary wrote output")
            ]
        )

        XCTAssertTrue(prompt.contains("Boss Watch: paused"))
        XCTAssertTrue(prompt.contains("Boss Pane: collapsed"))
        XCTAssertTrue(prompt.contains("Selected group: Selected"))
        XCTAssertTrue(prompt.contains("Local Ouro agents:"))
        XCTAssertTrue(prompt.contains("Bossy: selected_boss=true, status=ready"))
        XCTAssertTrue(prompt.contains("Mailbox warnings: machine: offline"))
        XCTAssertTrue(prompt.contains("Mailbox status: daemon=ok, attention=focused, needs_me=1, active_coding=3, blocked_coding=1"))
        XCTAssertTrue(prompt.contains("Needs me:"))
        XCTAssertTrue(prompt.contains("high: Approve deploy - Production rollout?"))
        XCTAssertTrue(prompt.contains("codex coding-1: status=blocked, workdir=/repo, checkpoint=none"))
        XCTAssertTrue(prompt.contains("Morning check: outcome=succeeded, ended=2026-01-01T00:01:00Z, operation=none, receipt=receipt.json, summary=line one line two"))
        XCTAssertTrue(prompt.contains("Recent workspace changes:"))
        XCTAssertTrue(prompt.contains("Transcript updated - Primary wrote output"))
        XCTAssertTrue(prompt.contains("* Selected"))
        XCTAssertTrue(prompt.contains("- Other"))
        XCTAssertTrue(prompt.contains("git=feature (dirty, +2/-1)"))
        XCTAssertTrue(prompt.contains("friend=Dana (human, friend)"))
        XCTAssertTrue(prompt.contains("transcript=/logs/primary.txt"))
        XCTAssertTrue(prompt.contains("notes=multi line notes"))
        XCTAssertTrue(prompt.contains("Waiting prompts"))
        XCTAssertTrue(prompt.contains("Proceed? 1) yes"))
        // flag (b): the raw machine-facing fields are KEPT (the boss uses
        // `action` as a stable join key, `reason` as the auditable detail) AND
        // an additive `plain=` field carries the human sentence so the boss can
        // relay it without decoding the rawValue.
        XCTAssertTrue(prompt.contains("Primary: action=autoResume, reason=trusted auto-resume, plain=Resumes its last conversation automatically."))
        XCTAssertTrue(prompt.contains("66666666-6666-6666-6666-666666666666: action=manualActionNeeded"))
        XCTAssertTrue(prompt.contains("plain=No resumable session — needs you to start it fresh."))
        XCTAssertTrue(prompt.contains("ok, source=boss, action=sendInput, target=Primary, result=sent continue"))
        XCTAssertTrue(prompt.contains("skipped, source=operator, action=recover, target=none, result=not trusted"))
    }

    /// FIX 3: the action-log summary the boss reads must label an in-flight ack
    /// honestly ("in progress"), not "ok". An in-flight ack has succeeded == true,
    /// so the old `succeeded ? "ok" : "skipped"` reported a false success TO the boss.
    /// A settled success stays "ok"; a settled failure stays "skipped".
    func testCheckInPromptLabelsInFlightActionAsPendingNotOk() {
        let (state, summary) = makeFixture()
        var mutated = state
        mutated.actionLog = [
            WorkbenchActionLogEntry(
                occurredAt: Date(timeIntervalSince1970: 300),
                source: "boss",
                action: "connect",
                result: "Connecting Bossy to Workbench…",
                succeeded: true,
                isInFlight: true
            ),
            WorkbenchActionLogEntry(
                occurredAt: Date(timeIntervalSince1970: 200),
                source: "boss",
                action: "sendInput",
                targetName: "Primary",
                result: "sent continue",
                succeeded: true
            ),
            WorkbenchActionLogEntry(
                occurredAt: Date(timeIntervalSince1970: 100),
                source: "operator",
                action: "recover",
                result: "not trusted",
                succeeded: false
            )
        ]
        let prompt = BossAgentPromptBuilder().checkInPrompt(
            question: "q",
            state: mutated,
            summary: summary,
            executableHealth: [:],
            gitStatus: [:],
            machineFriend: SessionFriend.machineOwner(),
            waitingPrompts: [:]
        )
        // The in-flight ack reports an honest pending status, never "ok".
        XCTAssertTrue(
            prompt.contains("in progress, source=boss, action=connect"),
            "an in-flight ack must be labeled 'in progress' to the boss, not 'ok'"
        )
        XCTAssertFalse(
            prompt.contains("ok, source=boss, action=connect"),
            "an in-flight ack must NOT report outcome=ok to the boss"
        )
        // The settled success still reads "ok"; the settled failure still "skipped".
        XCTAssertTrue(prompt.contains("ok, source=boss, action=sendInput"))
        XCTAssertTrue(prompt.contains("skipped, source=operator, action=recover"))
    }

    func testCheckInPromptRendersUnavailableAndEmptyMailboxVariants() {
        let dashboard = BossDashboardSnapshot(
            agentName: "Boss",
            daemonStatus: "unknown",
            daemonMode: "unknown",
            attentionLabel: "quiet",
            openObligations: 0,
            activeCodingAgents: 0,
            blockedCodingAgents: 0,
            needsMeItems: [],
            codingItems: [],
            habitHistory: HabitHistoryPanelModel(summaries: []),
            observedAt: nil,
            availability: .mailbox(
                machineIssue: nil,
                needsMeIssue: "needs-me: unavailable",
                codingIssue: "coding: unavailable",
                habitHistoryIssue: nil
            )
        )
        let state = WorkspaceState(projects: [])
        let summary = WorkspaceSummarizer().summarize(state)

        let prompt = BossAgentPromptBuilder().checkInPrompt(
            question: "status?",
            state: state,
            summary: summary,
            dashboard: dashboard
        )

        XCTAssertTrue(prompt.contains("Selected group: none"))
        XCTAssertTrue(prompt.contains("Mailbox warnings: needs-me: unavailable; coding: unavailable"))
        XCTAssertTrue(prompt.contains("needs_me=unknown, active_coding=unknown, blocked_coding=unknown"))
        XCTAssertTrue(prompt.contains("Habit history: no recent runs"))
        XCTAssertTrue(prompt.contains("- no configured recovery plans"))
    }

    func testCheckInPromptRendersHabitHistoryUnavailable() {
        let dashboard = BossDashboardSnapshot(
            agentName: "Boss",
            daemonStatus: "unknown",
            daemonMode: "unknown",
            attentionLabel: "quiet",
            openObligations: 0,
            activeCodingAgents: 0,
            blockedCodingAgents: 0,
            needsMeItems: [],
            codingItems: [],
            habitHistory: HabitHistoryPanelModel(summaries: [], isAvailable: false, issue: "habit-history: sync failed"),
            observedAt: nil,
            availability: BossDashboardAvailability(
                machineAvailable: true,
                needsMeAvailable: true,
                codingAvailable: true,
                habitHistoryAvailable: false,
                issues: ["habit-history: sync failed"]
            )
        )
        let prompt = BossAgentPromptBuilder().checkInPrompt(
            question: "status?",
            state: WorkspaceState(),
            summary: WorkspaceSummarizer().summarize(WorkspaceState()),
            dashboard: dashboard
        )

        XCTAssertTrue(prompt.contains("Habit history unavailable: habit-history: sync failed"))
    }

    func testCheckInPromptRendersFallbacksForOrphanSnapshotsCleanGitAndExpandedPane() {
        var unavailableHistory = HabitHistoryPanelModel(summaries: [], isAvailable: false, issue: nil)
        unavailableHistory.statusMessage = nil
        let dashboard = BossDashboardSnapshot(
            agentName: "Boss",
            daemonStatus: "unknown",
            daemonMode: "unknown",
            attentionLabel: "quiet",
            openObligations: 0,
            activeCodingAgents: 0,
            blockedCodingAgents: 0,
            needsMeItems: [],
            codingItems: [],
            habitHistory: unavailableHistory,
            observedAt: nil
        )
        let orphanId = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let state = WorkspaceState(
            bossPaneCollapsed: false,
            projects: [WorkbenchProject(name: "Only", rootPath: "/only")]
        )
        let summary = WorkspaceSummary(
            boss: BossAgentSelection(agentName: "Boss"),
            processSnapshots: [
                ProcessSnapshot(id: orphanId, name: "Orphan", status: .running, attention: .idle, latestRunId: nil, summary: "No matching entry")
            ],
            recoveryPlans: []
        )

        let prompt = BossAgentPromptBuilder().checkInPrompt(
            question: "status?",
            state: state,
            summary: summary,
            dashboard: dashboard,
            gitStatus: [orphanId: GitSessionStatus(isRepo: true, branch: "main", dirty: false)],
            waitingPrompts: [orphanId: "ignored fallback"]
        )

        XCTAssertTrue(prompt.contains("Boss Pane: expanded"))
        XCTAssertTrue(prompt.contains("Habit history unavailable"))
        XCTAssertTrue(prompt.contains("group=unknown"))
        XCTAssertTrue(prompt.contains("trust=unknown"))
        XCTAssertTrue(prompt.contains("archived=false"))
        XCTAssertTrue(prompt.contains("owner=unknown"))
        XCTAssertTrue(prompt.contains("git=main (clean)"))
        XCTAssertTrue(prompt.contains("ignored fallback"))
    }
}
