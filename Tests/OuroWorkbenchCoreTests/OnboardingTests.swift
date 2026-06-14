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

    func testEmptyBossSurfacesChooseCopyWithoutBlankName() {
        // Unresolved boss + more than one usable agent: the readiness must offer a
        // human choice with honest copy — never "The selected boss  is not
        // installed" with a blank name (the empty-boss regression from killing the
        // hardcoded default).
        let readiness = WorkbenchOnboardingAdvisor().readiness(
            boss: BossAgentSelection(agentName: ""),
            agents: [
                OuroAgentRecord(name: "ouroboros", bundlePath: "/b/ouroboros.ouro", configPath: "/b/ouroboros.ouro/agent.json", status: .ready, detail: "ready"),
                OuroAgentRecord(name: "slugger", bundlePath: "/b/slugger.ouro", configPath: "/b/slugger.ouro/agent.json", status: .ready, detail: "ready")
            ],
            mcpRegistration: nil
        )

        XCTAssertEqual(readiness.state, .needsAgent)
        XCTAssertEqual(readiness.headline, "Choose this machine's boss")
        XCTAssertEqual(readiness.selectedBossName, "")
        XCTAssertTrue(readiness.detail.contains("Choose which local agent"))
        XCTAssertFalse(readiness.detail.contains("The selected boss  is"))
        XCTAssertEqual(Set(readiness.repairSteps.map(\.id)), ["use-ouroboros", "use-slugger"])
        XCTAssertTrue(readiness.repairSteps.allSatisfy { $0.actor == .humanChoice })
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

    func testWorkbenchMCPStepUsesRuntimeInjectionFramingNotBundleRegistration() {
        // RUNTIME-INJECTION repoint: the `workbench-mcp` readiness step is no longer "register the
        // MCP into the bundle" — it means "is runtime injection available" (binary present) + the
        // bundle is clean of any stale entry. The step's copy must carry the runtime framing and
        // must NOT claim it registers anything into the bundle.
        let step = try! XCTUnwrap(
            WorkbenchOnboardingAdvisor().readiness(
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
                    serverName: "ouro_workbench",
                    commandPath: "/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP",
                    agentConfigPath: "/tmp/slugger.ouro/agent.json",
                    status: .notRegistered,
                    detail: "binary missing"
                ),
                providerChecks: [
                    "outward": OnboardingProviderCheckResult(lane: "outward", state: .passed, detail: "ok"),
                    "inner": OnboardingProviderCheckResult(lane: "inner", state: .passed, detail: "ok")
                ]
            ).repairSteps.first { $0.id == "workbench-mcp" }
        )
        XCTAssertEqual(step.title, "Connect Workbench tools")
        XCTAssertFalse(step.title.lowercased().contains("register"))
    }

    func testReadyDetailUsesRuntimeInjectionFraming() {
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
                serverName: "ouro_workbench",
                commandPath: "/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP",
                agentConfigPath: "/tmp/slugger.ouro/agent.json",
                status: .registered,
                detail: "registered"
            ),
            providerChecks: [
                "outward": OnboardingProviderCheckResult(lane: "outward", state: .passed, detail: "ok"),
                "inner": OnboardingProviderCheckResult(lane: "inner", state: .passed, detail: "ok")
            ]
        )
        XCTAssertEqual(readiness.state, .ready)
        XCTAssertTrue(readiness.detail.contains("Workbench tools"))
        XCTAssertFalse(readiness.detail.lowercased().contains("registered"))
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

    // MARK: - R1.1: daemon- and creds-aware readiness (re-applied onto the 4-arg signature)

    private func readyAgentWithBothLanes(name: String = "slugger") -> OuroAgentRecord {
        OuroAgentRecord(
            name: name,
            bundlePath: "/tmp/\(name).ouro",
            configPath: "/tmp/\(name).ouro/agent.json",
            status: .ready,
            detail: "ready",
            humanFacing: OuroAgentLane(provider: "minimax", model: "MiniMax-M2.7"),
            agentFacing: OuroAgentLane(provider: "openai-codex", model: "gpt-5.5")
        )
    }

    private func registeredSnapshot(name: String = "slugger") -> BossWorkbenchMCPRegistrationSnapshot {
        BossWorkbenchMCPRegistrationSnapshot(
            agentName: name,
            serverName: "ouro-workbench",
            commandPath: "/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP",
            agentConfigPath: "/tmp/\(name).ouro/agent.json",
            status: .registered,
            detail: "registered"
        )
    }

    /// Live's `.ready` gate also requires both provider lanes to have passed their live
    /// checks (the `providerChecks` machine live added). These passing checks let a
    /// fully-configured agent reach `.ready` so the daemon×creds matrix can assert the
    /// "everything good" corner; `.needsCredentials` / `.needsDaemon` short-circuit BEFORE
    /// this machine, so they are unaffected by it.
    private func passingProviderChecks() -> [String: OnboardingProviderCheckResult] {
        [
            "outward": OnboardingProviderCheckResult(lane: "outward", state: .passed, detail: "ok"),
            "inner": OnboardingProviderCheckResult(lane: "inner", state: .passed, detail: "ok")
        ]
    }

    func testReadinessDaemonDownIsNotReadyEvenWhenAgentsAndMCPAreFine() {
        let readiness = WorkbenchOnboardingAdvisor().readiness(
            boss: BossAgentSelection(agentName: "slugger"),
            agents: [readyAgentWithBothLanes()],
            mcpRegistration: registeredSnapshot(),
            providerChecks: passingProviderChecks(),
            daemonLiveness: .down
        )

        XCTAssertEqual(readiness.state, .needsDaemon)
        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(readiness.selectedBossName, "slugger")
        // App-executable remediation, not a human-typed CLI step.
        let daemonStep = readiness.repairSteps.first { $0.id == "ensure-daemon" }
        XCTAssertNotNil(daemonStep)
        XCTAssertEqual(daemonStep?.actor, .agentRunnable)
        // The daemon step must be ordered first (you cannot act through a down daemon).
        XCTAssertEqual(readiness.repairSteps.first?.id, "ensure-daemon")
    }

    func testReadinessDaemonDownCopyHasNoCLIorDaemonSeams() {
        let readiness = WorkbenchOnboardingAdvisor().readiness(
            boss: BossAgentSelection(agentName: "slugger"),
            agents: [readyAgentWithBothLanes()],
            mcpRegistration: registeredSnapshot(),
            providerChecks: passingProviderChecks(),
            daemonLiveness: .down
        )

        let daemonStep = readiness.repairSteps.first { $0.id == "ensure-daemon" }
        let humanFacing = [readiness.headline, readiness.detail, daemonStep?.title ?? "", daemonStep?.detail ?? ""]
        for copy in humanFacing {
            let lowered = copy.lowercased()
            XCTAssertFalse(lowered.contains("ouro"), "human-facing copy leaked a CLI seam: \(copy)")
            XCTAssertFalse(lowered.contains("daemon"), "human-facing copy leaked the daemon seam: \(copy)")
            XCTAssertFalse(lowered.contains("ouro up"), "human-facing copy leaked a CLI verb: \(copy)")
        }
        // Raw verbs are allowed only in the audit-lane command array.
        XCTAssertEqual(daemonStep?.command.first, "ouro")
    }

    func testReadinessCredsAbsentIsADistinctState() throws {
        let credlessAgent = OuroAgentRecord(
            name: "slugger",
            bundlePath: "/tmp/slugger.ouro",
            configPath: "/tmp/slugger.ouro/agent.json",
            status: .ready,
            detail: "ready",
            humanFacing: OuroAgentLane(provider: nil, model: nil),
            agentFacing: OuroAgentLane(provider: nil, model: nil)
        )
        let readiness = WorkbenchOnboardingAdvisor().readiness(
            boss: BossAgentSelection(agentName: "slugger"),
            agents: [credlessAgent],
            mcpRegistration: registeredSnapshot(),
            daemonLiveness: .up
        )

        XCTAssertEqual(readiness.state, .needsCredentials)
        XCTAssertFalse(readiness.isReady)
        // Distinct from generic needsRepair; carries a credential remediation step.
        let providerStep = try XCTUnwrap(readiness.repairSteps.first { $0.id == "request-provider-config" })
        // The provider step must NOT carry a pane-spawning `ouro connect providers` command:
        // that interactive CLI pane is the TTFA violation we deleted. It routes to the native
        // provider form instead, so it has no audit-lane command line.
        XCTAssertNil(providerStep.commandLine)
        XCTAssertTrue(providerStep.command.isEmpty)
        XCTAssertEqual(providerStep.actor, .humanRequired)
        // The UI routes provider-setup steps to the native form, so the step is classifiable.
        XCTAssertTrue(providerStep.isProviderSetup)
    }

    func testProviderSetupStepClassification() {
        // Provider-setup steps (the ones that previously spawned `ouro connect providers` panes)
        // are the steps the UI routes to the native provider form. Non-provider steps are not.
        let providerIds = ["request-provider-config", "outward-lane", "inner-lane"]
        for id in providerIds {
            let step = OnboardingRepairStep(id: id, actor: .humanRequired, title: "t", detail: "d")
            XCTAssertTrue(step.isProviderSetup, "\(id) should be a provider-setup step")
        }
        let other = OnboardingRepairStep(id: "ensure-daemon", actor: .agentRunnable, title: "t", detail: "d")
        XCTAssertFalse(other.isProviderSetup)
    }

    func testReadinessAllFourDaemonCredsCombos() {
        let advisor = WorkbenchOnboardingAdvisor()
        let withCreds = readyAgentWithBothLanes()
        let withoutCreds = OuroAgentRecord(
            name: "slugger",
            bundlePath: "/tmp/slugger.ouro",
            configPath: "/tmp/slugger.ouro/agent.json",
            status: .ready,
            detail: "ready",
            humanFacing: OuroAgentLane(provider: nil, model: nil),
            agentFacing: OuroAgentLane(provider: nil, model: nil)
        )
        let boss = BossAgentSelection(agentName: "slugger")
        let snapshot = registeredSnapshot()
        let checks = passingProviderChecks()

        // daemon up × creds present (+ passing live checks) -> ready
        XCTAssertEqual(
            advisor.readiness(boss: boss, agents: [withCreds], mcpRegistration: snapshot, providerChecks: checks, daemonLiveness: .up).state,
            .ready
        )
        // daemon up × creds absent -> needsCredentials
        XCTAssertEqual(
            advisor.readiness(boss: boss, agents: [withoutCreds], mcpRegistration: snapshot, providerChecks: checks, daemonLiveness: .up).state,
            .needsCredentials
        )
        // daemon down × creds present -> needsDaemon (daemon wins)
        XCTAssertEqual(
            advisor.readiness(boss: boss, agents: [withCreds], mcpRegistration: snapshot, providerChecks: checks, daemonLiveness: .down).state,
            .needsDaemon
        )
        // daemon down × creds absent -> needsDaemon (daemon still wins; cannot act through a down daemon)
        XCTAssertEqual(
            advisor.readiness(boss: boss, agents: [withoutCreds], mcpRegistration: snapshot, providerChecks: checks, daemonLiveness: .down).state,
            .needsDaemon
        )
    }

    func testReadinessDefaultsToDaemonUpWhenLivenessOmitted() {
        // Back-compat: the existing call (no `daemonLiveness:`) still resolves to a daemon-up
        // reading — `.needsDaemon` never appears unless the caller passes `.down`.
        let readiness = WorkbenchOnboardingAdvisor().readiness(
            boss: BossAgentSelection(agentName: "slugger"),
            agents: [readyAgentWithBothLanes()],
            mcpRegistration: registeredSnapshot(),
            providerChecks: passingProviderChecks()
        )
        XCTAssertEqual(readiness.state, .ready)
    }

    /// `.needsCredentials` is COMPLEMENTARY to live's per-lane `providerChecks` machine, not a
    /// duplicate: `providerChecks` live-checks a *configured* lane (and can fail it), whereas
    /// `.needsCredentials` fires only when there is NO usable lane at all (no provider in
    /// either lane). An agent with one configured lane is never `.needsCredentials` — it flows
    /// into the per-lane providerChecks path instead.
    func testNeedsCredentialsIsComplementaryToProviderChecks() {
        let advisor = WorkbenchOnboardingAdvisor()
        let boss = BossAgentSelection(agentName: "slugger")
        let snapshot = registeredSnapshot()
        // One usable lane (outward) → NOT needsCredentials; the inner lane flows into the
        // per-lane providerChecks path, so the state is the existing needsRepair, not creds.
        let oneLaneAgent = OuroAgentRecord(
            name: "slugger",
            bundlePath: "/tmp/slugger.ouro",
            configPath: "/tmp/slugger.ouro/agent.json",
            status: .ready,
            detail: "ready",
            humanFacing: OuroAgentLane(provider: "minimax", model: "MiniMax-M2.7"),
            agentFacing: OuroAgentLane(provider: nil, model: nil)
        )
        let readiness = advisor.readiness(
            boss: boss,
            agents: [oneLaneAgent],
            mcpRegistration: snapshot,
            providerChecks: ["outward": OnboardingProviderCheckResult(lane: "outward", state: .passed, detail: "ok")],
            daemonLiveness: .up
        )
        XCTAssertNotEqual(readiness.state, .needsCredentials)
        XCTAssertEqual(readiness.state, .needsRepair)
        XCTAssertFalse(readiness.repairSteps.contains { $0.id == "request-provider-config" })
        // The configured lane goes through the providerChecks path (here: inner is unconfigured).
        XCTAssertTrue(readiness.repairSteps.contains { $0.id == "inner-lane" })
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

    func testRecentSessionScannerReadsCodexArchivedJsonl() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let archiveURL = temporaryDirectory
            .appendingPathComponent(".codex/archived_sessions/session.jsonl")
        try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"id":"archived-1","timestamp":"2026-05-26T11:00:00Z","cwd":"/Users/ari/Projects/archive","prompt":"Ship archive import"}"#
            .write(to: archiveURL, atomically: true, encoding: .utf8)

        let candidates = RecentSessionScanner(
            homeURL: temporaryDirectory,
            now: now,
            sqlite3URL: temporaryDirectory.appendingPathComponent("missing-sqlite3")
        ).scan()
        let candidate = try XCTUnwrap(candidates.first { $0.id == "codex:archived-1" })

        XCTAssertEqual(candidate.source, .openAICodex)
        XCTAssertEqual(candidate.agentKind, .openAICodex)
        XCTAssertEqual(candidate.title, "Ship archive import")
        XCTAssertEqual(candidate.workingDirectory, "/Users/ari/Projects/archive")
        XCTAssertEqual(candidate.resumeCommand, ["codex", "resume", "archived-1"])
        XCTAssertTrue(candidate.evidencePaths.contains(archiveURL.path))
        XCTAssertGreaterThanOrEqual(candidate.confidence, 0.8)
    }

    func testRecentSessionScannerReadsCodexManualRecoveryJsonl() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let recoveryURL = temporaryDirectory
            .appendingPathComponent(".codex/manual-recovery-20260526/recovery.jsonl")
        try FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"sessionId":"manual-1","updatedAt":"2026-05-26T11:10:00Z","workingDirectory":"/Users/ari/Projects/manual","summary":"Manual recovery fixture"}"#
            .write(to: recoveryURL, atomically: true, encoding: .utf8)

        let candidates = RecentSessionScanner(
            homeURL: temporaryDirectory,
            now: now,
            sqlite3URL: temporaryDirectory.appendingPathComponent("missing-sqlite3")
        ).scan()
        let candidate = try XCTUnwrap(candidates.first { $0.id == "codex:manual-1" })

        XCTAssertEqual(candidate.source, .openAICodex)
        XCTAssertEqual(candidate.title, "Manual recovery fixture")
        XCTAssertEqual(candidate.workingDirectory, "/Users/ari/Projects/manual")
        XCTAssertEqual(candidate.resumeCommand, ["codex", "resume", "manual-1"])
        XCTAssertTrue(candidate.evidencePaths.contains(recoveryURL.path))
    }

    func testRecentSessionScannerReadsClaudeTaskJson() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let taskURL = temporaryDirectory
            .appendingPathComponent(".claude/tasks/task.json")
        try FileManager.default.createDirectory(at: taskURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"sessionId":"task-1","updatedAt":"2026-05-26T11:20:00Z","cwd":"/Users/ari/Projects/claude-task","summary":"Claude task fixture"}"#
            .write(to: taskURL, atomically: true, encoding: .utf8)

        let candidates = RecentSessionScanner(
            homeURL: temporaryDirectory,
            now: now,
            sqlite3URL: temporaryDirectory.appendingPathComponent("missing-sqlite3")
        ).scan()
        let candidate = try XCTUnwrap(candidates.first { $0.id == "claude:task-1" })

        XCTAssertEqual(candidate.source, .claudeCode)
        XCTAssertEqual(candidate.agentKind, .claudeCode)
        XCTAssertEqual(candidate.title, "Claude task fixture")
        XCTAssertEqual(candidate.workingDirectory, "/Users/ari/Projects/claude-task")
        XCTAssertEqual(candidate.resumeCommand, ["claude", "--resume", "task-1"])
        XCTAssertTrue(candidate.evidencePaths.contains(taskURL.path))
    }

    func testRecentSessionScannerUnionsCodexSqliteAndSessionIndex() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let codexDir = temporaryDirectory.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: codexDir.appendingPathComponent("state_5.sqlite").path, contents: Data())
        try #"{"id":"codex-index","thread_name":"Index fallback","updated_at":"2026-05-26T11:25:00Z"}"#
            .write(to: codexDir.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        let sqliteURL = temporaryDirectory.appendingPathComponent("sqlite3")
        try """
        #!/bin/zsh
        printf "codex-sqlite\\tSQLite task\\t/Users/ari/Projects/sqlite\\tmain\\t1779796200000\\n"
        """.write(to: sqliteURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sqliteURL.path)

        let candidates = RecentSessionScanner(
            homeURL: temporaryDirectory,
            now: now,
            sqlite3URL: sqliteURL,
            liveProcessLister: { [] }
        ).scan()

        XCTAssertTrue(candidates.contains { $0.id == "codex:codex-sqlite" })
        XCTAssertTrue(candidates.contains { $0.id == "codex:codex-index" })
    }

    func testRecentSessionScannerIgnoresStaleCodexArchive() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let archiveURL = temporaryDirectory
            .appendingPathComponent(".codex/archived_sessions/stale.jsonl")
        try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"id":"stale-archive","timestamp":"2026-05-01T11:00:00Z","cwd":"/Users/ari/Projects/stale","prompt":"Old work"}"#
            .write(to: archiveURL, atomically: true, encoding: .utf8)

        let candidates = RecentSessionScanner(
            homeURL: temporaryDirectory,
            now: now,
            sqlite3URL: temporaryDirectory.appendingPathComponent("missing-sqlite3")
        ).scan()

        XCTAssertFalse(candidates.contains { $0.id == "codex:stale-archive" })
    }

    func testRecentSessionScannerSkipsMalformedCodexArchiveLines() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let archiveURL = temporaryDirectory
            .appendingPathComponent(".codex/archived_sessions/mixed.jsonl")
        try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try [
            "not-json",
            #"{"id":"valid-after-malformed","timestamp":"2026-05-26T11:00:00Z","cwd":"/Users/ari/Projects/valid","prompt":"Valid after malformed"}"#
        ].joined(separator: "\n").write(to: archiveURL, atomically: true, encoding: .utf8)

        let candidates = RecentSessionScanner(
            homeURL: temporaryDirectory,
            now: now,
            sqlite3URL: temporaryDirectory.appendingPathComponent("missing-sqlite3")
        ).scan()

        XCTAssertTrue(candidates.contains { $0.id == "codex:valid-after-malformed" })
    }

    func testRecentSessionScannerDropsCodexArchiveWithoutSessionId() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let archiveURL = temporaryDirectory
            .appendingPathComponent(".codex/archived_sessions/no-id.jsonl")
        try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"timestamp":"2026-05-26T11:00:00Z","cwd":"/Users/ari/Projects/no-id","prompt":"No id"}"#
            .write(to: archiveURL, atomically: true, encoding: .utf8)

        let candidates = RecentSessionScanner(
            homeURL: temporaryDirectory,
            now: now,
            sqlite3URL: temporaryDirectory.appendingPathComponent("missing-sqlite3")
        ).scan()

        XCTAssertFalse(candidates.contains { $0.workingDirectory == "/Users/ari/Projects/no-id" })
    }

    func testRecentSessionScannerKeepsCodexArchiveWithoutWorkingDirectoryAsRecoverable() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let archiveURL = temporaryDirectory
            .appendingPathComponent(".codex/archived_sessions/no-cwd.jsonl")
        try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"id":"recoverable-no-cwd","timestamp":"2026-05-26T11:00:00Z","prompt":"Recoverable without cwd"}"#
            .write(to: archiveURL, atomically: true, encoding: .utf8)

        let candidates = RecentSessionScanner(
            homeURL: temporaryDirectory,
            now: now,
            sqlite3URL: temporaryDirectory.appendingPathComponent("missing-sqlite3")
        ).scan()
        let candidate = try XCTUnwrap(candidates.first { $0.id == "codex:recoverable-no-cwd" })

        XCTAssertEqual(candidate.workingDirectory, temporaryDirectory.path)
        XCTAssertLessThanOrEqual(candidate.confidence, 0.75)
        XCTAssertEqual(candidate.resumeCommand, ["codex", "resume", "recoverable-no-cwd"])
    }

    func testRecentSessionScannerPrefersHigherConfidenceDuplicate() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let codexDir = temporaryDirectory.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(
            at: codexDir.appendingPathComponent("archived_sessions"),
            withIntermediateDirectories: true
        )
        try #"{"id":"duplicate","thread_name":"Index duplicate","updated_at":"2026-05-26T10:00:00Z"}"#
            .write(to: codexDir.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
        let archiveURL = codexDir.appendingPathComponent("archived_sessions/duplicate.jsonl")
        try #"{"id":"duplicate","timestamp":"2026-05-26T11:00:00Z","cwd":"/Users/ari/Projects/high-confidence","prompt":"Archive duplicate"}"#
            .write(to: archiveURL, atomically: true, encoding: .utf8)

        let candidates = RecentSessionScanner(
            homeURL: temporaryDirectory,
            now: now,
            sqlite3URL: temporaryDirectory.appendingPathComponent("missing-sqlite3")
        ).scan()
        let duplicates = candidates.filter { $0.id == "codex:duplicate" }

        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates.first?.workingDirectory, "/Users/ari/Projects/high-confidence")
        XCTAssertTrue(duplicates.first?.evidencePaths.contains(archiveURL.path) == true)
    }

    func testRecentSessionScannerFallsBackToSessionIndexWhenSqliteMissingOrUnexecutable() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let codexDir = temporaryDirectory.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: codexDir.appendingPathComponent("state_5.sqlite").path, contents: Data())
        try #"{"id":"index-only","thread_name":"Index survives missing sqlite","updated_at":"2026-05-26T11:45:00Z"}"#
            .write(to: codexDir.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        let candidates = RecentSessionScanner(
            homeURL: temporaryDirectory,
            now: now,
            sqlite3URL: temporaryDirectory.appendingPathComponent("not-executable-sqlite3")
        ).scan()
        let candidate = try XCTUnwrap(candidates.first { $0.id == "codex:index-only" })

        XCTAssertEqual(candidate.resumeCommand, ["codex", "resume", "index-only"])
        XCTAssertEqual(candidate.source, .openAICodex)
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
        XCTAssertEqual(proposal.groups.first?.id, "ouro-workbench")
        XCTAssertEqual(proposal.groups.first?.terminals.first?.name, "Claude: Ship the onboarding concierge")
        XCTAssertEqual(proposal.selectedTerminalCount, 1)
    }

    func testRepositoryRootWalksUpToGitMarker() {
        let gitRoots: Set<String> = ["/Users/ari/code/myrepo"]
        let resolved = WorkspaceGrouping.repositoryRoot(
            for: "/Users/ari/code/myrepo/web/src/components"
        ) { gitRoots.contains($0) }
        XCTAssertEqual(resolved, "/Users/ari/code/myrepo")
    }

    func testRepositoryRootReturnsNilOutsideAnyRepo() {
        let resolved = WorkspaceGrouping.repositoryRoot(for: "/Users/ari/Downloads/scratch") { _ in false }
        XCTAssertNil(resolved)
    }

    func testRepositoryRootReturnsDirectoryItselfWhenItIsTheRoot() {
        let resolved = WorkspaceGrouping.repositoryRoot(for: "/Users/ari/code/myrepo/") { $0 == "/Users/ari/code/myrepo" }
        XCTAssertEqual(resolved, "/Users/ari/code/myrepo")
    }

    func testImportProposalGroupsSameRepoDifferentSubdirsIntoOneGroup() {
        // Two sessions in the SAME repo, launched from different subdirectories.
        // The old path heuristic split these into separate groups; git-root
        // grouping puts them in one group named after the repo.
        let base = "/Users/ari/code/myrepo"
        let candidates = [
            RecentSessionCandidate(
                id: "a", source: .claudeCode, agentKind: .claudeCode, title: "frontend work",
                workingDirectory: base + "/web/src", lastActiveAt: Date(timeIntervalSince1970: 200),
                resumeCommand: ["claude"], summary: "", evidencePaths: [], confidence: 0.9,
                repositoryRoot: base
            ),
            RecentSessionCandidate(
                id: "b", source: .openAICodex, agentKind: .openAICodex, title: "api work",
                workingDirectory: base + "/server", lastActiveAt: Date(timeIntervalSince1970: 100),
                resumeCommand: ["codex"], summary: "", evidencePaths: [], confidence: 0.9,
                repositoryRoot: base
            ),
        ]
        let groups = WorkbenchImportProposalBuilder().build(candidates: candidates).groups
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "myrepo")
        XCTAssertEqual(groups.first?.rootPath, base)
        XCTAssertEqual(groups.first?.terminals.count, 2)
    }

    func testImportProposalSeparatesDistinctRepos() {
        let candidates = [
            RecentSessionCandidate(
                id: "a", source: .claudeCode, agentKind: .claudeCode, title: "x",
                workingDirectory: "/Users/ari/code/alpha/src", lastActiveAt: Date(),
                resumeCommand: ["claude"], summary: "", evidencePaths: [], confidence: 0.9,
                repositoryRoot: "/Users/ari/code/alpha"
            ),
            RecentSessionCandidate(
                id: "b", source: .claudeCode, agentKind: .claudeCode, title: "y",
                workingDirectory: "/Users/ari/code/beta", lastActiveAt: Date(),
                resumeCommand: ["claude"], summary: "", evidencePaths: [], confidence: 0.9,
                repositoryRoot: "/Users/ari/code/beta"
            ),
        ]
        let groups = WorkbenchImportProposalBuilder().build(candidates: candidates).groups
        XCTAssertEqual(Set(groups.map(\.name)), ["alpha", "beta"])
    }

    func testImportProposalPreferredGroupNameOverridesRepoGrouping() {
        let candidates = [
            RecentSessionCandidate(
                id: "a", source: .claudeCode, agentKind: .claudeCode, title: "x",
                workingDirectory: "/Users/ari/code/alpha", lastActiveAt: Date(),
                resumeCommand: ["claude"], summary: "", evidencePaths: [], confidence: 0.9,
                preferredGroupName: "My Cmux Space", repositoryRoot: "/Users/ari/code/alpha"
            ),
            RecentSessionCandidate(
                id: "b", source: .claudeCode, agentKind: .claudeCode, title: "y",
                workingDirectory: "/Users/ari/code/beta", lastActiveAt: Date(),
                resumeCommand: ["claude"], summary: "", evidencePaths: [], confidence: 0.9,
                preferredGroupName: "My Cmux Space", repositoryRoot: "/Users/ari/code/beta"
            ),
        ]
        let groups = WorkbenchImportProposalBuilder().build(candidates: candidates).groups
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "My Cmux Space")
    }

    func testImportProposalKeepsGroupIDsUniqueAcrossGroups() {
        // Two distinct roots whose display names slugify identically
        // ("My Project" vs "My-Project" -> "my-project"). Without de-duping,
        // both groups would share a slug-derived id, breaking Identifiable
        // ForEach + selection.
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
        XCTAssertEqual(Set(ids).count, 2, "group ids must be unique: \(ids)")
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
            rootPath: "/Users/ari/Projects/ouro-workbench"
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
        XCTAssertTrue(rendered.contains("- ouro-workbench: 1 active terminal"))
        XCTAssertTrue(rendered.contains("workbench_request_action"))
        XCTAssertTrue(rendered.contains("workbench_sense"))
        // Sense doubles as an in-app help oracle: it carries the action protocol
        // and the operator keyboard shortcuts so the boss can answer how-do-I
        // questions without leaving the tool.
        XCTAssertTrue(rendered.contains("ouro-workbench-actions"))
        XCTAssertTrue(rendered.contains("operator keyboard shortcuts"))
        XCTAssertTrue(rendered.contains("Boss Check In"))
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
            selectedByDefault: false
        )
        return WorkbenchImportProposal(
            generatedAt: Date(),
            groups: [
                ProposedWorkbenchGroup(
                    id: "g",
                    name: "g",
                    rootPath: "/tmp/g",
                    terminals: [first, second]
                )
            ],
            ignoredCandidates: []
        )
    }

}
