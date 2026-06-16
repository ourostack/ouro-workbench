import XCTest
@testable import OuroWorkbenchCore

final class BossDashboardTests: XCTestCase {
    func testBuildsDashboardForSelectedBossAgent() {
        let machine = MailboxMachineView(
            overview: MailboxMachineOverview(
                observedAt: "2026-05-23T00:00:00Z",
                primaryEntryPoint: "http://127.0.0.1:6876",
                daemon: MailboxMachineDaemonSummary(status: "running", mode: "dev", mailboxUrl: "http://127.0.0.1:6876"),
                runtime: MailboxRuntimeSummary(version: "0.1.0-alpha.657"),
                totals: MailboxMachineTotals(openObligations: 4, activeCodingAgents: 2, blockedCodingAgents: 1)
            ),
            agents: [
                MailboxMachineAgentView(
                    agentName: "slugger",
                    enabled: true,
                    attention: MailboxAttentionSummary(level: "active", label: "active"),
                    obligations: MailboxCountSummary(openCount: 2),
                    coding: MailboxCountSummary(activeCount: 1, blockedCount: 0)
                ),
                MailboxMachineAgentView(
                    agentName: "boss-b",
                    enabled: true,
                    attention: nil,
                    obligations: nil,
                    coding: nil
                )
            ]
        )
        let needsMe = MailboxNeedsMeView(items: [
            MailboxNeedsMeItem(
                urgency: "blocking-obligation",
                label: "Needs review",
                detail: "decision ready",
                ref: nil,
                ageMs: 100
            )
        ])
        let coding = MailboxCodingSummary(
            totalCount: 1,
            activeCount: 1,
            blockedCount: 0,
            items: [
                MailboxCodingItem(
                    id: "codex-1",
                    runner: "codex",
                    status: "running",
                    workdir: "/repo",
                    lastActivityAt: nil,
                    checkpoint: "building",
                    taskRef: nil
                )
            ]
        )

        let snapshot = BossDashboardBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            machine: machine,
            needsMe: needsMe,
            coding: coding
        )

        XCTAssertEqual(snapshot.daemonStatus, "running")
        XCTAssertEqual(snapshot.daemonVersion, "0.1.0-alpha.657")
        XCTAssertEqual(snapshot.openObligations, 2)
        XCTAssertEqual(snapshot.activeCodingAgents, 1)
        XCTAssertEqual(snapshot.needsMeItems.map(\.label), ["Needs review"])
        XCTAssertEqual(snapshot.knownAgentNames, ["boss-b", "slugger"])
        XCTAssertEqual(snapshot.oneLineStatus, "1 item waiting on you")
    }

    func testPromptIncludesDashboardSignals() {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            workingDirectory: "/repo"
        )
        let state = WorkspaceState(projects: [project], processEntries: [entry])
        let summary = WorkspaceSummarizer().summarize(state)
        let dashboard = BossDashboardSnapshot(
            agentName: "slugger",
            daemonStatus: "running",
            daemonMode: "dev",
            attentionLabel: "active",
            openObligations: 1,
            activeCodingAgents: 1,
            blockedCodingAgents: 0,
            needsMeItems: [
                MailboxNeedsMeItem(urgency: "owed-reply", label: "Ari is waiting", detail: "reply needed", ref: nil, ageMs: nil)
            ],
            codingItems: [
                MailboxCodingItem(id: "codex-1", runner: "codex", status: "running", workdir: "/repo", lastActivityAt: nil, checkpoint: "green", taskRef: nil)
            ],
            observedAt: nil
        )

        let prompt = BossAgentPromptBuilder().checkInPrompt(
            question: "what is going on?",
            state: state,
            summary: summary,
            dashboard: dashboard
        )

        XCTAssertTrue(prompt.contains("Mailbox status: daemon=running"))
        XCTAssertTrue(prompt.contains("Needs me:"))
        XCTAssertTrue(prompt.contains("Ari is waiting"))
        XCTAssertTrue(prompt.contains("Mailbox coding sessions:"))
    }

    func testPromptIncludesHabitHistorySignals() {
        let dashboard = BossDashboardSnapshot(
            agentName: "slugger",
            daemonStatus: "running",
            daemonMode: "dev",
            attentionLabel: "active",
            openObligations: 0,
            activeCodingAgents: 0,
            blockedCodingAgents: 0,
            needsMeItems: [],
            codingItems: [],
            habitHistory: HabitHistoryPanelModel(summaries: [
                MailboxHabitSessionSummary(
                    runId: "run-history",
                    habitName: "heartbeat",
                    operationId: "habit:heartbeat",
                    status: "surfaced",
                    triggeredAt: "2026-06-11T10:00:00.000Z",
                    completedAt: "2026-06-11T10:01:00.000Z",
                    summary: "Queued iMessage and recorded the route.",
                    decisions: [],
                    pending: MailboxHabitSummaryPending(count: 0, files: []),
                    messagesSent: [],
                    toolsUsed: [],
                    producedRefs: [],
                    errors: [],
                    warnings: [],
                    nextLikelyStep: nil,
                    sources: MailboxHabitSummarySources(
                        receipt: "arc/flight-recorder/habit-receipts/run-history.json",
                        session: "state/habit-sessions/run-history/session.json",
                        pending: "state/habit-sessions/run-history/pending",
                        runtimeState: "state/habits/heartbeat.json"
                    )
                )
            ]),
            observedAt: nil
        )

        let prompt = BossAgentPromptBuilder().checkInPrompt(
            question: "what changed?",
            state: WorkspaceState(),
            summary: WorkspaceSummarizer().summarize(WorkspaceState()),
            dashboard: dashboard
        )

        XCTAssertTrue(prompt.contains("Habit history:"))
        XCTAssertTrue(prompt.contains("heartbeat: outcome=surfaced"))
        XCTAssertTrue(prompt.contains("operation=habit:heartbeat"))
        XCTAssertTrue(prompt.contains("receipt=arc/flight-recorder/habit-receipts/run-history.json"))
    }

    func testPromptIncludesEmptyAndUnavailableHabitHistoryStates() {
        let emptyDashboard = BossDashboardSnapshot(
            agentName: "slugger",
            daemonStatus: "running",
            daemonMode: "dev",
            attentionLabel: "active",
            openObligations: 0,
            activeCodingAgents: 0,
            blockedCodingAgents: 0,
            needsMeItems: [],
            codingItems: [],
            observedAt: nil
        )

        let emptyPrompt = BossAgentPromptBuilder().checkInPrompt(
            question: "history?",
            state: WorkspaceState(),
            summary: WorkspaceSummarizer().summarize(WorkspaceState()),
            dashboard: emptyDashboard
        )
        XCTAssertTrue(emptyPrompt.contains("Habit history: no recent runs"))

        let unavailableDashboard = BossDashboardBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            machine: nil,
            needsMe: nil,
            coding: nil,
            habitHistory: nil,
            availability: BossDashboardAvailability(
                machineAvailable: false,
                needsMeAvailable: false,
                codingAvailable: false,
                habitHistoryAvailable: false,
                issues: ["habit-history: timed out"]
            )
        )
        let unavailablePrompt = BossAgentPromptBuilder().checkInPrompt(
            question: "history?",
            state: WorkspaceState(),
            summary: WorkspaceSummarizer().summarize(WorkspaceState()),
            dashboard: unavailableDashboard
        )
        XCTAssertTrue(unavailablePrompt.contains("Habit history unavailable: habit-history: timed out"))
    }

    func testMailboxAvailabilityCarriesHabitHistoryFailures() {
        let availability = BossDashboardAvailability.mailbox(
            machineIssue: nil,
            needsMeIssue: nil,
            codingIssue: nil,
            habitHistoryIssue: "habit-history: timed out"
        )

        XCTAssertTrue(availability.machineAvailable)
        XCTAssertTrue(availability.needsMeAvailable)
        XCTAssertTrue(availability.codingAvailable)
        XCTAssertFalse(availability.habitHistoryAvailable)
        XCTAssertEqual(availability.issues, ["habit-history: timed out"])

        let snapshot = BossDashboardBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            machine: nil,
            needsMe: nil,
            coding: nil,
            habitHistory: nil,
            availability: availability
        )

        XCTAssertFalse(snapshot.habitHistory.isAvailable)
        XCTAssertEqual(snapshot.habitHistory.statusMessage, "Habit history unavailable: habit-history: timed out")
    }

    func testUnavailableNeedsMeDoesNotRenderAsZeroWaiting() {
        let snapshot = BossDashboardBuilder().build(
            boss: BossAgentSelection(agentName: "slugger"),
            machine: nil,
            needsMe: nil,
            coding: MailboxCodingSummary(totalCount: 0, activeCount: 0, blockedCount: 0, items: []),
            availability: BossDashboardAvailability(
                machineAvailable: false,
                needsMeAvailable: false,
                codingAvailable: true,
                issues: ["needs-me: timed out"]
            )
        )

        XCTAssertEqual(snapshot.oneLineStatus, "Needs-me status unavailable")

        let prompt = BossAgentPromptBuilder().checkInPrompt(
            question: "what is going on?",
            state: WorkspaceState(),
            summary: WorkspaceSummarizer().summarize(WorkspaceState()),
            dashboard: snapshot
        )

        XCTAssertTrue(prompt.contains("Mailbox warnings: needs-me: timed out"))
        XCTAssertTrue(prompt.contains("needs_me=unknown"))
        XCTAssertFalse(prompt.contains("needs_me=0"))
    }

    func testOneLineStatusCoversCodingAvailabilityActivePluralityAndAttentionFallback() {
        XCTAssertEqual(
            BossDashboardSnapshot(
                agentName: "slugger",
                daemonStatus: "running",
                daemonMode: "dev",
                attentionLabel: "idle",
                openObligations: 0,
                activeCodingAgents: 0,
                blockedCodingAgents: 0,
                needsMeItems: [],
                codingItems: [],
                observedAt: nil,
                availability: BossDashboardAvailability(machineAvailable: true, needsMeAvailable: true, codingAvailable: false)
            ).oneLineStatus,
            "Coding status unavailable"
        )
        XCTAssertEqual(
            BossDashboardSnapshot(agentName: "slugger", daemonStatus: "running", daemonMode: "dev", attentionLabel: "idle", openObligations: 0, activeCodingAgents: 2, blockedCodingAgents: 0, needsMeItems: [], codingItems: [], observedAt: nil).oneLineStatus,
            "2 active coding agents"
        )
        XCTAssertEqual(
            BossDashboardSnapshot(agentName: "slugger", daemonStatus: "running", daemonMode: "dev", attentionLabel: "idle", openObligations: 2, activeCodingAgents: 0, blockedCodingAgents: 0, needsMeItems: [
                MailboxNeedsMeItem(urgency: "u", label: "one", detail: "d", ref: nil, ageMs: nil),
                MailboxNeedsMeItem(urgency: "u", label: "two", detail: "d", ref: nil, ageMs: nil)
            ], codingItems: [], observedAt: nil).oneLineStatus,
            "2 items waiting on you"
        )
        XCTAssertEqual(
            BossDashboardSnapshot(agentName: "slugger", daemonStatus: "running", daemonMode: "dev", attentionLabel: "idle", openObligations: 0, activeCodingAgents: 1, blockedCodingAgents: 0, needsMeItems: [], codingItems: [], observedAt: nil).oneLineStatus,
            "1 active coding agent"
        )
        XCTAssertEqual(
            BossDashboardSnapshot(agentName: "slugger", daemonStatus: "running", daemonMode: "dev", attentionLabel: "idle", openObligations: 0, activeCodingAgents: 0, blockedCodingAgents: 0, needsMeItems: [], codingItems: [], observedAt: nil).oneLineStatus,
            "idle"
        )
        XCTAssertEqual(HabitHistoryPanelModel(isAvailable: false).statusMessage, "Habit history unavailable")
    }
}
