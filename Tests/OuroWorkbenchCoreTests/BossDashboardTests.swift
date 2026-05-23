import XCTest
@testable import OuroWorkbenchCore

final class BossDashboardTests: XCTestCase {
    func testBuildsDashboardForSelectedBossAgent() {
        let machine = MailboxMachineView(
            overview: MailboxMachineOverview(
                observedAt: "2026-05-23T00:00:00Z",
                primaryEntryPoint: "http://127.0.0.1:6876",
                daemon: MailboxMachineDaemonSummary(status: "running", mode: "dev", mailboxUrl: "http://127.0.0.1:6876"),
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
}
