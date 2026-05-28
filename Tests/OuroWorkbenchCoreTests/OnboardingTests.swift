import XCTest
@testable import OuroWorkbenchCore

final class OnboardingTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ouro-workbench-onboarding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testAdvisorKeepsBossReadinessSeparateFromDeskBridgeSetup() {
        let advisor = WorkbenchOnboardingAdvisor()
        let agents = [
            OuroAgentRecord(
                name: "slugger",
                bundlePath: "/Users/ari/AgentBundles/slugger.ouro",
                configPath: "/Users/ari/AgentBundles/slugger.ouro/agent.json",
                status: .ready,
                detail: "ready",
                humanFacing: OuroAgentLane(provider: "minimax", model: "MiniMax-M2.7"),
                agentFacing: OuroAgentLane(provider: "openai-codex", model: "gpt-5.5")
            )
        ]
        let readiness = advisor.readiness(
            boss: BossAgentSelection(agentName: "slugger"),
            agents: agents,
            mcpRegistration: BossWorkbenchMCPRegistrationSnapshot(
                agentName: "slugger",
                serverName: "ouro-workbench",
                commandPath: "/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP",
                agentConfigPath: "/Users/ari/AgentBundles/slugger.ouro/agent.json",
                status: .registered,
                detail: "registered"
            ),
            providerChecks: [
                "outward": OnboardingProviderCheckResult(lane: "outward", state: .passed, detail: "ok"),
                "inner": OnboardingProviderCheckResult(lane: "inner", state: .passed, detail: "ok")
            ]
        )

        XCTAssertEqual(readiness.state, .ready)
        XCTAssertEqual(readiness.selectedBossName, "slugger")

        let bridge = DeskBridgePlanner().plan(agentName: "slugger", terminalKind: .claudeCode)
        XCTAssertEqual(bridge.setupCommand, ["ouro", "setup", "--tool", "claude-code", "--agent", "slugger"])
        XCTAssertFalse(bridge.detail.contains("boss"))
    }

    func testAdvisorSurfacesProviderAndMCPRepairs() {
        let readiness = WorkbenchOnboardingAdvisor().readiness(
            boss: BossAgentSelection(agentName: "slugger"),
            agents: [
                OuroAgentRecord(
                    name: "slugger",
                    bundlePath: "/tmp/slugger.ouro",
                    configPath: "/tmp/slugger.ouro/agent.json",
                    status: .ready,
                    detail: "ready",
                    humanFacing: OuroAgentLane(provider: nil, model: nil),
                    agentFacing: OuroAgentLane(provider: "openai-codex", model: "gpt-5.5")
                )
            ],
            mcpRegistration: BossWorkbenchMCPRegistrationSnapshot(
                agentName: "slugger",
                serverName: "ouro-workbench",
                commandPath: "/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP",
                agentConfigPath: "/tmp/slugger.ouro/agent.json",
                status: .notRegistered,
                detail: "Workbench MCP is not registered"
            )
        )

        XCTAssertEqual(readiness.state, .needsRepair)
        XCTAssertTrue(readiness.repairSteps.contains { $0.id == "outward-lane" && $0.actor == .humanChoice })
        XCTAssertTrue(readiness.repairSteps.contains { $0.id == "workbench-mcp" && $0.actor == .agentRunnable })
    }

    func testAdvisorRequiresLiveProviderChecksBeforeReady() {
        let readiness = WorkbenchOnboardingAdvisor().readiness(
            boss: BossAgentSelection(agentName: "slugger"),
            agents: [
                OuroAgentRecord(
                    name: "slugger",
                    bundlePath: "/tmp/slugger.ouro",
                    configPath: "/tmp/slugger.ouro/agent.json",
                    status: .ready,
                    detail: "ready",
                    humanFacing: OuroAgentLane(provider: "minimax", model: "MiniMax-M2.7"),
                    agentFacing: OuroAgentLane(provider: "openai-codex", model: "gpt-5.5")
                )
            ],
            mcpRegistration: BossWorkbenchMCPRegistrationSnapshot(
                agentName: "slugger",
                serverName: "ouro-workbench",
                commandPath: "/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP",
                agentConfigPath: "/tmp/slugger.ouro/agent.json",
                status: .registered,
                detail: "registered"
            )
        )

        XCTAssertEqual(readiness.state, .needsRepair)
        XCTAssertTrue(readiness.repairSteps.contains { $0.id == "check-outward" && $0.actor == .agentRunnable })
        XCTAssertTrue(readiness.repairSteps.contains { $0.id == "check-inner" && $0.actor == .agentRunnable })
    }

    func testAdvisorBlocksOnFailedProviderCheck() {
        let readiness = WorkbenchOnboardingAdvisor().readiness(
            boss: BossAgentSelection(agentName: "slugger"),
            agents: [
                OuroAgentRecord(
                    name: "slugger",
                    bundlePath: "/tmp/slugger.ouro",
                    configPath: "/tmp/slugger.ouro/agent.json",
                    status: .ready,
                    detail: "ready",
                    humanFacing: OuroAgentLane(provider: "minimax", model: "MiniMax-M2.7"),
                    agentFacing: OuroAgentLane(provider: "openai-codex", model: "gpt-5.5")
                )
            ],
            mcpRegistration: BossWorkbenchMCPRegistrationSnapshot(
                agentName: "slugger",
                serverName: "ouro-workbench",
                commandPath: "/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP",
                agentConfigPath: "/tmp/slugger.ouro/agent.json",
                status: .registered,
                detail: "registered"
            ),
            providerChecks: [
                "outward": OnboardingProviderCheckResult(lane: "outward", state: .failed, detail: "vault locked"),
                "inner": OnboardingProviderCheckResult(lane: "inner", state: .passed, detail: "ok")
            ]
        )

        XCTAssertEqual(readiness.state, .needsRepair)
        XCTAssertTrue(readiness.repairSteps.contains {
            $0.id == "repair-outward-provider" &&
                $0.actor == .humanRequired &&
                $0.detail == "vault locked"
        })
    }

    func testRecentSessionScannerFindsClaudeCodexAndShellCandidates() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let claudeURL = temporaryDirectory
            .appendingPathComponent(".claude/projects/-Users-ari-Projects-ouro-workbench--claude-worktrees-polish/session.jsonl")
        try FileManager.default.createDirectory(at: claudeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try [
            #"{"type":"attachment","sessionId":"claude-1","cwd":"/Users/ari/Projects/ouro-workbench/.claude/worktrees/polish","timestamp":"2026-05-25T12:00:00.000Z"}"#,
            #"{"type":"queue-operation","operation":"enqueue","sessionId":"claude-1","timestamp":"2026-05-25T12:01:00.000Z","content":"Polish the onboarding flow until it feels native."}"#
        ].joined(separator: "\n").write(to: claudeURL, atomically: true, encoding: .utf8)

        let codexURL = temporaryDirectory.appendingPathComponent(".codex/session_index.jsonl")
        try FileManager.default.createDirectory(at: codexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"id":"codex-1","thread_name":"Review Workbench onboarding","updated_at":"2026-05-25T14:00:00.000Z"}"#
            .write(to: codexURL, atomically: true, encoding: .utf8)

        let historyURL = temporaryDirectory.appendingPathComponent(".zsh_history")
        try ": 1779796800:0;gh copilot suggest 'fix swift compile'\n"
            .write(to: historyURL, atomically: true, encoding: .utf8)

        let scanner = RecentSessionScanner(
            homeURL: temporaryDirectory,
            now: now,
            lookback: 7 * 24 * 60 * 60,
            sqlite3URL: temporaryDirectory.appendingPathComponent("missing-sqlite3")
        )
        let candidates = scanner.scan()

        XCTAssertTrue(candidates.contains { $0.id == "claude:claude-1" && $0.agentKind == .claudeCode })
        XCTAssertTrue(candidates.contains { $0.id == "codex:codex-1" && $0.agentKind == .openAICodex })
        XCTAssertTrue(candidates.contains { $0.source == .githubCopilotCLI && $0.agentKind == .githubCopilotCLI })
    }

    func testRecentSessionScannerImportsLiveCmuxClaudePanelsWithGroupNames() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let claudeURL = temporaryDirectory
            .appendingPathComponent(".claude/projects/-Users-ari-Projects-ouroboros-agent-harness/live-1.jsonl")
        try FileManager.default.createDirectory(at: claudeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try [
            #"{"sessionId":"live-1","cwd":"/Users/ari/Projects/ouroboros-agent-harness","timestamp":"2026-05-26T11:55:00.000Z"}"#,
            #"{"sessionId":"live-1","content":"Older history title","timestamp":"2026-05-26T11:56:00.000Z"}"#
        ].joined(separator: "\n").write(to: claudeURL, atomically: true, encoding: .utf8)

        let cmuxURL = temporaryDirectory.appendingPathComponent("cmux-session.json")
        try """
        {
          "windows": [{
            "tabManager": {
              "workspaces": [{
                "customTitle": "Ouroboros Harness Work",
                "currentDirectory": "/Users/ari/Projects/ouroboros-agent-harness",
                "processTitle": "Terminal 2",
                "statusEntries": [{
                  "value": "Needs input",
                  "timestamp": 1779796740
                }],
                "panels": [{
                  "title": "* Debug Slugger unresponsive",
                  "directory": "/Users/ari/Projects/ouroboros-agent-harness",
                  "terminal": {
                    "workingDirectory": "/Users/ari/Projects/ouroboros-agent-harness"
                  },
                  "ttyName": "ttys008"
                }]
              }]
            }
          }]
        }
        """.write(to: cmuxURL, atomically: true, encoding: .utf8)

        let scanner = RecentSessionScanner(
            homeURL: temporaryDirectory,
            now: now,
            lookback: 7 * 24 * 60 * 60,
            sqlite3URL: temporaryDirectory.appendingPathComponent("missing-sqlite3"),
            cmuxSessionURL: cmuxURL,
            liveProcessLister: {
                [
                    RecentSessionScanner.LiveTerminalProcess(
                        pid: 123,
                        ttyName: "s008",
                        command: "/Users/ari/.local/bin/claude --dangerously-skip-permissions --session-id live-1 --settings {\"hooks\":{}}"
                    )
                ]
            }
        )

        let candidates = scanner.scan()
        let candidate = try XCTUnwrap(candidates.first { $0.id == "claude:live-1" })

        XCTAssertEqual(candidate.source, .cmux)
        XCTAssertEqual(candidate.title, "Debug Slugger unresponsive")
        XCTAssertEqual(candidate.workingDirectory, "/Users/ari/Projects/ouroboros-agent-harness")
        XCTAssertEqual(candidate.resumeCommand, ["claude", "--dangerously-skip-permissions", "--resume", "live-1"])
        XCTAssertEqual(candidate.preferredGroupName, "Ouroboros Harness Work")
        XCTAssertTrue(candidate.evidencePaths.contains(cmuxURL.path))
        XCTAssertGreaterThanOrEqual(candidate.confidence, 0.98)

        let proposal = WorkbenchImportProposalBuilder().build(candidates: candidates, now: now)
        XCTAssertEqual(proposal.groups.first?.name, "Ouroboros Harness Work")
        XCTAssertEqual(proposal.groups.first?.terminals.first?.name, "Claude: Debug Slugger unresponsive")
    }

    func testRecentSessionScannerFallsBackToLiveClaudeProcessesWithoutCmuxState() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let scanner = RecentSessionScanner(
            homeURL: temporaryDirectory,
            now: now,
            lookback: 7 * 24 * 60 * 60,
            sqlite3URL: temporaryDirectory.appendingPathComponent("missing-sqlite3"),
            cmuxSessionURL: temporaryDirectory.appendingPathComponent("missing-cmux.json"),
            liveProcessLister: {
                [
                    RecentSessionScanner.LiveTerminalProcess(
                        pid: 456,
                        ttyName: "s009",
                        command: #"/bin/zsh -lc "claude --permission-mode bypassPermissions --session-id live-2""#
                    )
                ]
            }
        )

        let candidate = try XCTUnwrap(scanner.scan().first { $0.id == "claude:live-2" })

        XCTAssertEqual(candidate.source, .claudeCode)
        XCTAssertEqual(candidate.resumeCommand, ["claude", "--permission-mode", "bypassPermissions", "--resume", "live-2"])
        XCTAssertEqual(candidate.workingDirectory, temporaryDirectory.path)
        XCTAssertTrue(candidate.evidencePaths.contains("process:456"))
    }

    func testCodexSQLiteScannerUsesSingleValidOrderByQuery() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let codexURL = temporaryDirectory.appendingPathComponent(".codex/state_5.sqlite")
        try FileManager.default.createDirectory(at: codexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: codexURL.path, contents: Data())

        let sqliteURL = temporaryDirectory.appendingPathComponent("sqlite3")
        try """
        #!/bin/zsh
        query="${argv[-1]}"
        count=$(printf "%s" "$query" | grep -o "order by" | wc -l | tr -d " ")
        if [[ "$count" != "1" ]]; then
          exit 42
        fi
        printf "codex-live\\tShip cmux import\\t/Users/ari/Projects/ouro-workbench\\tmain\\t1779796800000\\n"
        """.write(to: sqliteURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sqliteURL.path)

        let scanner = RecentSessionScanner(
            homeURL: temporaryDirectory,
            now: now,
            lookback: 7 * 24 * 60 * 60,
            sqlite3URL: sqliteURL,
            cmuxSessionURL: temporaryDirectory.appendingPathComponent("missing-cmux.json"),
            liveProcessLister: { [] }
        )

        let candidate = try XCTUnwrap(scanner.scan().first { $0.id == "codex:codex-live" })
        XCTAssertEqual(candidate.workingDirectory, "/Users/ari/Projects/ouro-workbench")
        XCTAssertEqual(candidate.resumeCommand, ["codex", "resume", "codex-live"])
    }

    func testImportProposalGroupsClaudeWorktreesByOwningProject() {
        let candidate = RecentSessionCandidate(
            id: "claude:1",
            source: .claudeCode,
            agentKind: .claudeCode,
            title: "Ship the onboarding concierge",
            workingDirectory: "/Users/ari/Projects/ouro-workbench/.claude/worktrees/polish",
            lastActiveAt: Date(),
            resumeCommand: ["claude", "--resume", "1"],
            summary: "Build onboarding.",
            evidencePaths: ["/tmp/session.jsonl"],
            confidence: 0.92
        )

        let proposal = WorkbenchImportProposalBuilder().build(candidates: [candidate])

        XCTAssertEqual(proposal.groups.map(\.name), ["ouro-workbench"])
        XCTAssertEqual(proposal.groups.first?.rootPath, "/Users/ari/Projects/ouro-workbench")
        XCTAssertEqual(proposal.groups.first?.deskTrackSlug, "ouro-workbench")
        XCTAssertEqual(proposal.groups.first?.terminals.first?.name, "Claude: Ship the onboarding concierge")
        XCTAssertEqual(proposal.selectedTerminalCount, 1)
    }

    func testImportProposalKeepsDeskTaskSlugsUniqueWithinGroup() {
        let candidates = (1...2).map { index in
            RecentSessionCandidate(
                id: "codex:\(index)",
                source: .openAICodex,
                agentKind: .openAICodex,
                title: "Same title",
                workingDirectory: "/Users/ari/Projects/ouro-workbench",
                lastActiveAt: Date(timeIntervalSince1970: TimeInterval(index)),
                resumeCommand: ["codex", "resume", "\(index)"],
                summary: "Same",
                evidencePaths: [],
                confidence: 0.9
            )
        }

        let slugs = WorkbenchImportProposalBuilder()
            .build(candidates: candidates)
            .groups
            .flatMap(\.terminals)
            .map(\.deskTaskSlug)

        XCTAssertEqual(Set(slugs).count, 2)
        XCTAssertTrue(slugs.contains("same-title"))
        XCTAssertTrue(slugs.contains("same-title-2"))
    }

    func testImportProposalKeepsGroupIDsUniqueAcrossGroups() {
        // Two distinct roots whose display names slugify identically
        // ("My Project" vs "My-Project" -> "my-project"). Without de-duping,
        // both groups would share an id/deskTrackSlug, breaking Identifiable
        // ForEach + selection + the Desk mirror.
        let candidates = [
            RecentSessionCandidate(
                id: "codex:a",
                source: .openAICodex,
                agentKind: .openAICodex,
                title: "Alpha task",
                workingDirectory: "/Users/ari/Alpha/My Project",
                lastActiveAt: Date(timeIntervalSince1970: 2),
                resumeCommand: ["codex", "resume", "a"],
                summary: "Alpha",
                evidencePaths: [],
                confidence: 0.9
            ),
            RecentSessionCandidate(
                id: "codex:b",
                source: .openAICodex,
                agentKind: .openAICodex,
                title: "Beta task",
                workingDirectory: "/Users/ari/Beta/My-Project",
                lastActiveAt: Date(timeIntervalSince1970: 1),
                resumeCommand: ["codex", "resume", "b"],
                summary: "Beta",
                evidencePaths: [],
                confidence: 0.9
            )
        ]

        let groups = WorkbenchImportProposalBuilder().build(candidates: candidates).groups
        XCTAssertEqual(groups.count, 2)
        let ids = groups.map(\.id)
        let slugs = groups.map(\.deskTrackSlug)
        XCTAssertEqual(Set(ids).count, 2, "group ids must be unique: \(ids)")
        XCTAssertEqual(Set(slugs).count, 2, "desk track slugs must be unique: \(slugs)")
    }

    func testImportProposalCuratesDefaultSelectionsInsteadOfStampedingTabs() {
        let candidates = (1...10).map { index in
            RecentSessionCandidate(
                id: "codex:\(index)",
                source: .openAICodex,
                agentKind: .openAICodex,
                title: "Task \(index)",
                workingDirectory: "/Users/ari/Projects/ouro-workbench",
                lastActiveAt: Date(timeIntervalSince1970: TimeInterval(index)),
                resumeCommand: ["codex", "resume", "\(index)"],
                summary: "Task \(index)",
                evidencePaths: [],
                confidence: 0.94
            )
        }

        let proposal = WorkbenchImportProposalBuilder().build(candidates: candidates)
        let selected = proposal.groups.flatMap(\.terminals).filter(\.selectedByDefault)

        XCTAssertEqual(proposal.groups.first?.terminals.count, 10)
        XCTAssertEqual(selected.count, 6)
        XCTAssertEqual(selected.first?.candidate.id, "codex:10")
        XCTAssertEqual(selected.last?.candidate.id, "codex:5")
    }

    func testWorkbenchSenseRendererExposesSenseContractAndTools() {
        let project = WorkbenchProject(
            name: "ouro-workbench",
            rootPath: "/Users/ari/Projects/ouro-workbench",
            deskTrackSlug: "ouro-workbench"
        )
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            arguments: ["--yolo"],
            workingDirectory: project.rootPath
        )
        let state = WorkspaceState(
            selectedProjectId: project.id,
            selectedEntryId: entry.id,
            projects: [project],
            processEntries: [entry]
        )

        let rendered = WorkbenchSenseRenderer().render(
            state: state,
            summary: WorkspaceSummarizer().summarize(state)
        )

        XCTAssertTrue(rendered.contains("## workbench sense"))
        XCTAssertTrue(rendered.contains("desk_track=ouro-workbench"))
        XCTAssertTrue(rendered.contains("workbench_request_action"))
        XCTAssertTrue(rendered.contains("workbench_sense"))
    }

    func testToggleSelectionFlipsTerminalSelectionAndCount() {
        var proposal = makeTwoTerminalProposal()
        XCTAssertEqual(proposal.selectedTerminalCount, 1, "second terminal should start unselected")

        let toggledOn = proposal.toggleSelection(groupID: "g", terminalID: "second")
        XCTAssertEqual(toggledOn, true)
        XCTAssertEqual(proposal.selectedTerminalCount, 2)
        XCTAssertTrue(proposal.groups[0].terminals[1].selectedByDefault)

        let toggledOff = proposal.toggleSelection(groupID: "g", terminalID: "first")
        XCTAssertEqual(toggledOff, false)
        XCTAssertEqual(proposal.selectedTerminalCount, 1)
        XCTAssertFalse(proposal.groups[0].terminals[0].selectedByDefault)
    }

    func testToggleSelectionReturnsNilForUnknownIDs() {
        var proposal = makeTwoTerminalProposal()
        XCTAssertNil(proposal.toggleSelection(groupID: "missing", terminalID: "first"))
        XCTAssertNil(proposal.toggleSelection(groupID: "g", terminalID: "missing"))
        XCTAssertEqual(proposal.selectedTerminalCount, 1, "selection should be untouched on unknown IDs")
    }

    func testSetSelectionBulkSelectsAndClearsAGroup() {
        var proposal = makeTwoTerminalProposal()

        proposal.setSelection(groupID: "g", selected: true)
        XCTAssertEqual(proposal.selectedTerminalCount, 2)
        XCTAssertTrue(proposal.groups[0].terminals.allSatisfy(\.selectedByDefault))

        proposal.setSelection(groupID: "g", selected: false)
        XCTAssertEqual(proposal.selectedTerminalCount, 0)
        XCTAssertTrue(proposal.groups[0].terminals.allSatisfy { !$0.selectedByDefault })
    }

    private func makeTwoTerminalProposal() -> WorkbenchImportProposal {
        let first = ProposedTerminalImport(
            id: "first",
            candidate: RecentSessionCandidate(
                id: "first",
                source: .openAICodex,
                agentKind: .openAICodex,
                title: "First",
                workingDirectory: "/tmp/g",
                lastActiveAt: Date(),
                resumeCommand: ["codex", "resume", "first"],
                summary: "first",
                evidencePaths: [],
                confidence: 0.9
            ),
            name: "Codex: First",
            deskTaskSlug: "first",
            selectedByDefault: true
        )
        let second = ProposedTerminalImport(
            id: "second",
            candidate: RecentSessionCandidate(
                id: "second",
                source: .openAICodex,
                agentKind: .openAICodex,
                title: "Second",
                workingDirectory: "/tmp/g",
                lastActiveAt: Date(),
                resumeCommand: ["codex", "resume", "second"],
                summary: "second",
                evidencePaths: [],
                confidence: 0.8
            ),
            name: "Codex: Second",
            deskTaskSlug: "second",
            selectedByDefault: false
        )
        return WorkbenchImportProposal(
            generatedAt: Date(),
            groups: [
                ProposedWorkbenchGroup(
                    id: "g",
                    name: "g",
                    rootPath: "/tmp/g",
                    deskTrackSlug: "g",
                    terminals: [first, second]
                )
            ],
            ignoredCandidates: []
        )
    }

    func testDeskMirrorWriterCreatesTracksAndTasksWithoutOverwriting() throws {
        let proposal = WorkbenchImportProposal(
            generatedAt: Date(),
            groups: [
                ProposedWorkbenchGroup(
                    id: "ouro-workbench",
                    name: "ouro-workbench",
                    rootPath: "/Users/ari/Projects/ouro-workbench",
                    deskTrackSlug: "ouro-workbench",
                    terminals: [
                        ProposedTerminalImport(
                            id: "codex:1",
                            candidate: RecentSessionCandidate(
                                id: "codex:1",
                                source: .openAICodex,
                                agentKind: .openAICodex,
                                title: "Onboarding",
                                workingDirectory: "/Users/ari/Projects/ouro-workbench",
                                lastActiveAt: Date(),
                                resumeCommand: ["codex", "resume", "1"],
                                summary: "Implement onboarding.",
                                evidencePaths: ["/tmp/state.sqlite"],
                                confidence: 0.94
                            ),
                            name: "Codex: Onboarding",
                            deskTaskSlug: "onboarding",
                            selectedByDefault: true
                        )
                    ]
                )
            ],
            ignoredCandidates: []
        )
        let writer = DeskMirrorWriter(deskRoot: temporaryDirectory)
        let changed = try writer.apply(proposal)

        XCTAssertTrue(changed.contains(temporaryDirectory.appendingPathComponent("ouro-workbench/track.md").path))
        XCTAssertTrue(changed.contains(temporaryDirectory.appendingPathComponent("ouro-workbench/onboarding/task.md").path))

        let trackURL = temporaryDirectory.appendingPathComponent("ouro-workbench/track.md")
        try "custom".write(to: trackURL, atomically: true, encoding: .utf8)
        _ = try writer.apply(proposal)
        XCTAssertEqual(try String(contentsOf: trackURL), "custom")
    }
}
