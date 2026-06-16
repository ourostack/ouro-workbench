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

    func testMissingNamedBossUsesInstalledBundleCopyAndReportAuditCommands() {
        let readiness = WorkbenchOnboardingAdvisor().readiness(
            boss: BossAgentSelection(agentName: "missing"),
            agents: [readyAgentWithBothLanes(name: "slugger")],
            mcpRegistration: nil
        )

        XCTAssertEqual(readiness.state, .needsAgent)
        XCTAssertTrue(readiness.detail.contains("selected boss missing is not installed"))

        let rendered = OnboardingReadinessReportRenderer().render(OnboardingReadiness(
            state: .needsAgent,
            headline: "Set up",
            detail: "Do it",
            selectedBossName: "missing",
            repairSteps: [OnboardingRepairStep(id: "hatch", actor: .humanChoice, title: "Hatch", detail: "Create", command: ["ouro", "hatch"])]
        ))
        XCTAssertTrue(rendered.contains("- hatch: ouro hatch"))
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

    func testAdvisorOffersHatchAndCloneWhenNoAgentsExist() {
        let readiness = WorkbenchOnboardingAdvisor().readiness(
            boss: BossAgentSelection(agentName: "slugger"),
            agents: [],
            mcpRegistration: nil
        )

        XCTAssertEqual(readiness.state, .needsAgent)
        XCTAssertEqual(readiness.repairSteps.map(\.id), ["hatch", "clone"])
        XCTAssertEqual(readiness.repairSteps.compactMap(\.commandLine).count, 2)
    }

    func testAdvisorRepairsSelectedAgentConfigAndRunningProviderCheck() {
        let readiness = WorkbenchOnboardingAdvisor().readiness(
            boss: BossAgentSelection(agentName: "slugger"),
            agents: [
                OuroAgentRecord(
                    name: "slugger",
                    bundlePath: "/bundles/slugger.ouro",
                    configPath: "/bundles/slugger.ouro/agent.json",
                    status: .invalidConfig,
                    detail: "missing model",
                    humanFacing: OuroAgentLane(provider: "minimax", model: "MiniMax-M2.7"),
                    agentFacing: OuroAgentLane(provider: "openai-codex", model: "gpt-5.5")
                )
            ],
            mcpRegistration: nil,
            providerChecks: [
                "outward": OnboardingProviderCheckResult(lane: "outward", state: .running, detail: "checking"),
                "inner": OnboardingProviderCheckResult(lane: "inner", state: .passed, detail: "ok")
            ]
        )

        XCTAssertEqual(readiness.state, .needsRepair)
        XCTAssertTrue(readiness.repairSteps.contains { $0.id == "repair-agent-config" && $0.command == ["ouro", "repair", "--agent", "slugger"] })
        XCTAssertTrue(readiness.repairSteps.contains { $0.id == "check-outward" && $0.title == "Checking outward provider" })
        XCTAssertTrue(readiness.repairSteps.contains { $0.id == "workbench-mcp" && $0.detail.contains("aren't available") })
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

    func testRecentCandidateCommandLineAndWorkbenchScanCoverShellAndSkipApps() throws {
        let project = WorkbenchProject(name: "Project", rootPath: "/Users/ari/code/project")
        let shell = ProcessEntry(projectId: project.id, name: "Shell", kind: .shell, executable: "/bin/zsh", arguments: ["-l"], workingDirectory: project.rootPath, notes: " shell notes ")
        let app = ProcessEntry(projectId: project.id, name: "App", kind: .command, executable: "/Applications/App.app", workingDirectory: project.rootPath)
        let run = ProcessRun(entryId: shell.id, status: .running, startedAt: Date(timeIntervalSince1970: 1), lastOutputAt: Date(timeIntervalSince1970: 2))
        let state = WorkspaceState(projects: [project], processEntries: [shell, app], processRuns: [run])

        let candidates = RecentSessionScanner(homeURL: temporaryDirectory).scanWorkbench(state: state)

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidate.source, RecentSessionSource.workbench)
        XCTAssertEqual(candidate.summary, "shell notes")
        XCTAssertEqual(candidate.resumeCommandLine, "/bin/zsh -l")
    }

    func testScannerCoversClaudeCodexShellAndSortingFallbackBranches() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let claudeProject = temporaryDirectory.appendingPathComponent(".claude/projects/-Users-ari-code-repo")
        try FileManager.default.createDirectory(at: claudeProject, withIntermediateDirectories: true)
        try #"{"content":[{"text":"Summarize a very long onboarding transcript that must be clipped on a word boundary before it becomes a proposal title for the UI because otherwise it is too long"}],"timestamp":"2026-05-26T11:00:00Z"}"#
            .write(to: claudeProject.appendingPathComponent("fallback-session.jsonl"), atomically: true, encoding: .utf8)
        try #"not-json"#
            .write(to: claudeProject.appendingPathComponent("ignored.jsonl"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: claudeProject.appendingPathComponent("ignored.jsonl").path)

        let codexURL = temporaryDirectory.appendingPathComponent(".codex/session_index.jsonl")
        try FileManager.default.createDirectory(at: codexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try [
            #"{"thread_name":"missing id","updated_at":"2026-05-26T10:00:00Z"}"#,
            #"{"id":"old","thread_name":"old","updated_at":"2020-01-01T00:00:00Z"}"#,
            #"{"id":"codex-fallback","updated_at":"2026-05-26T10:00:00Z"}"#
        ].joined(separator: "\n").write(to: codexURL, atomically: true, encoding: .utf8)

        let historyURL = temporaryDirectory.appendingPathComponent(".zsh_history")
        try [
            "not zsh",
            ": not-an-epoch:0;claude",
            ": 100:0;claude --session-id old",
            ": 1779796800:0;echo not-agent",
            ": 1779796800:0;gh copilot"
        ].joined(separator: "\n").write(to: historyURL, atomically: true, encoding: .utf8)

        let scanner = RecentSessionScanner(
            homeURL: temporaryDirectory,
            now: now,
            lookback: 7 * 24 * 60 * 60,
            sqlite3URL: temporaryDirectory.appendingPathComponent("missing-sqlite3"),
            liveProcessLister: {
                [
                    RecentSessionScanner.LiveTerminalProcess(pid: 1, ttyName: nil, command: "not claude"),
                    RecentSessionScanner.LiveTerminalProcess(pid: 2, ttyName: "??", command: "claude --model opus --add-dir /repo --session-id=live-eq")
                ]
            }
        )

        let candidates = scanner.scan()

        XCTAssertTrue(candidates.contains { $0.id == "claude:fallback-session" && $0.workingDirectory == "/Users/ari/code/repo" && $0.confidence == 0.92 })
        XCTAssertTrue(candidates.contains { $0.id == "codex:codex-fallback" && $0.title == "codex-fallback" })
        XCTAssertTrue(candidates.contains { $0.id == "claude:live-eq" && $0.resumeCommand == ["claude", "--model", "opus", "--add-dir", "/repo", "--resume", "live-eq"] })
        XCTAssertTrue(candidates.contains { $0.source == .githubCopilotCLI && $0.resumeCommand == ["gh", "copilot"] })
        XCTAssertEqual(RecentSessionScanner.titleFromPrompt(String(repeating: "x", count: 80))?.count, 72)
        XCTAssertNil(RecentSessionScanner.titleFromPrompt(" \n "))
    }

    func testRecentSessionScannerInternalHelpersCoverDefensiveBranches() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let scanner = RecentSessionScanner(homeURL: temporaryDirectory, now: now, sqlite3URL: temporaryDirectory.appendingPathComponent("missing"), liveProcessLister: { [] })

        let preRooted = RecentSessionCandidate(id: "rooted", source: .shellHistory, agentKind: nil, title: "Rooted", workingDirectory: temporaryDirectory.path, lastActiveAt: nil, resumeCommand: ["bash"], summary: "", evidencePaths: [], confidence: 0.6, repositoryRoot: "/repo")
        let dated = RecentSessionCandidate(id: "dated", source: .shellHistory, agentKind: nil, title: "Dated", workingDirectory: temporaryDirectory.path, lastActiveAt: now, resumeCommand: ["bash"], summary: "", evidencePaths: [], confidence: 0.6)
        let resolved = scanner.resolveRepositoryRoots([preRooted, dated])
        XCTAssertEqual(resolved.first?.id, "dated")
        XCTAssertEqual(resolved.first { $0.id == "rooted" }?.repositoryRoot, "/repo")

        XCTAssertTrue(scanner.recentFiles(under: temporaryDirectory.appendingPathComponent("missing"), pathExtension: "jsonl").isEmpty)
        let jsonURL = temporaryDirectory.appendingPathComponent("helpers.jsonl")
        try #"{"a":"first","content":{"text":"Nested text"},"timestamp":"2026-05-26T11:00:00Z"}"#
            .write(to: jsonURL, atomically: true, encoding: .utf8)
        let records = scanner.jsonLineObjects(jsonURL)
        XCTAssertEqual(scanner.firstString(records, keys: ["missing", "a"]), "first")
        XCTAssertNil(scanner.firstString([[:]], keys: ["missing"]))
        XCTAssertEqual(scanner.firstPrompt(records), "Nested text")
        XCTAssertNil(scanner.firstPrompt([["content": "   "]]))
        XCTAssertEqual(scanner.stringValue(["content": ["text": "object text"]]), "object text")
        XCTAssertEqual(scanner.stringValue([["text": "one"], ["text": "two"]]), "one\ntwo")
        XCTAssertNil(scanner.stringValue(42))
        XCTAssertNotNil(scanner.newestDate(in: records))
        XCTAssertNil(scanner.parseDate(nil))
        XCTAssertNotNil(scanner.parseDate("2026-05-26T11:00:00Z"))
        XCTAssertFalse(scanner.isRecent(nil))
        XCTAssertNil(scanner.inferredClaudeProjectPath(from: temporaryDirectory.appendingPathComponent("plain/session.jsonl")))
        XCTAssertEqual(scanner.parseZshHistoryLine(": 1779796800:0;claude")?.command, "claude")
        XCTAssertNil(scanner.parseZshHistoryLine("bad"))
        XCTAssertNil(scanner.parseZshHistoryLine(": bad;claude"))
        XCTAssertNil(RecentSessionScanner.parseProcessLine("bad line"))
        XCTAssertEqual(RecentSessionScanner.parseProcessLine("123 ttys001 claude --session-id abc")?.pid, 123)
        XCTAssertFalse(scanner.isClaudeProcess(command: " "))
        XCTAssertNil(scanner.claudeSessionId(from: "claude"))
        XCTAssertNil(scanner.claudeSessionId(from: " "))
        XCTAssertTrue(scanner.preservedClaudeResumeArguments(from: " ").isEmpty)
        XCTAssertEqual(scanner.preservedClaudeResumeArguments(from: "claude --model"), [])
        XCTAssertEqual(scanner.preservedClaudeResumeArguments(from: "claude --permission-mode=acceptEdits --add-dir=/repo --yolo"), ["--permission-mode=acceptEdits", "--add-dir=/repo", "--yolo"])
        XCTAssertNil(scanner.canonicalCommandTokens(" "))
        let low = RecentSessionCandidate(id: "same", source: .shellHistory, agentKind: nil, title: "low", workingDirectory: "/", lastActiveAt: nil, resumeCommand: [], summary: "", evidencePaths: [], confidence: 0.1)
        let high = RecentSessionCandidate(id: "same", source: .shellHistory, agentKind: nil, title: "high", workingDirectory: "/", lastActiveAt: nil, resumeCommand: [], summary: "", evidencePaths: [], confidence: 0.9)
        XCTAssertEqual(scanner.candidateById([high, low])["same"]?.title, "high")
        XCTAssertNil(scanner.cleanedCmuxTitle(" !!! "))
        XCTAssertEqual(scanner.normalizedTTYName("console"), "console")
    }

    func testCmuxScannerSkipsMalformedPanelsAndUsesFallbacks() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let cmuxURL = temporaryDirectory.appendingPathComponent("cmux-fallbacks.json")
        try """
        {
          "windows": [
            {"tabManager": {}},
            {"tabManager": {"workspaces": [{
              "processTitle": "Fallback Process",
              "statusEntries": [],
              "panels": [
                {"title": "!!!", "ttyName": null},
                {"title": "!!!", "ttyName": "ttys010"}
              ]
            }]}}
          ]
        }
        """.write(to: cmuxURL, atomically: true, encoding: .utf8)
        let scanner = RecentSessionScanner(
            homeURL: temporaryDirectory,
            now: now,
            sqlite3URL: temporaryDirectory.appendingPathComponent("missing-sqlite3"),
            cmuxSessionURL: cmuxURL,
            liveProcessLister: {
                [RecentSessionScanner.LiveTerminalProcess(pid: 7, ttyName: "ttys010", command: "claude --session-id cmux-fallback")]
            }
        )

        let candidate = try XCTUnwrap(scanner.scanCmuxSessions().first)

        XCTAssertEqual(candidate.title, "Live Claude Code session cmux-fal")
        XCTAssertEqual(candidate.workingDirectory, temporaryDirectory.path)
        XCTAssertEqual(candidate.summary, "Live cmux Claude Code panel in Fallback Process.")
        XCTAssertTrue(candidate.evidencePaths.contains("tty:ttys010"))
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

    func testCodexSQLiteScannerHandlesMalformedRowsHomeFallbackAndFailures() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let codexURL = temporaryDirectory.appendingPathComponent(".codex/state_5.sqlite")
        try FileManager.default.createDirectory(at: codexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: codexURL.path, contents: Data())

        let sqliteURL = temporaryDirectory.appendingPathComponent("sqlite3")
        try """
        #!/bin/sh
        printf 'bad\\n'
        printf 'codex-empty\\t\\t\\tmain\\t0\\n'
        """.write(to: sqliteURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sqliteURL.path)

        let scanner = RecentSessionScanner(homeURL: temporaryDirectory, now: now, sqlite3URL: sqliteURL, liveProcessLister: { [] })
        let candidate = try XCTUnwrap(scanner.scanCodex().first { $0.id == "codex:codex-empty" })

        XCTAssertEqual(candidate.title, "codex-empty")
        XCTAssertEqual(candidate.workingDirectory, temporaryDirectory.path)
        XCTAssertEqual(candidate.lastActiveAt, nil)
        XCTAssertEqual(candidate.summary, "codex-empty")
        XCTAssertEqual(candidate.confidence, 0.74)

        let failingSQLite = temporaryDirectory.appendingPathComponent("sqlite3-fail")
        try "#!/bin/sh\nexit 1\n".write(to: failingSQLite, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failingSQLite.path)
        XCTAssertTrue(RecentSessionScanner(homeURL: temporaryDirectory, now: now, sqlite3URL: failingSQLite, liveProcessLister: { [] }).scanCodex().isEmpty)
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

    func testRepositoryRootHandlesEmptyRootAndHomeParent() {
        XCTAssertNil(WorkspaceGrouping.repositoryRoot(for: "") { _ in true })
        XCTAssertEqual(WorkspaceGrouping.parentDirectory(of: "/Users"), "/")
        XCTAssertNil(WorkspaceGrouping.parentDirectory(of: "/"))
        XCTAssertEqual(WorkspaceGrouping.standardizedDirectory("/Users/ari///"), "/Users/ari")
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

    func testImportProposalCoversNamesSortingIgnoredAndSelectionGuards() {
        let sameTime = Date(timeIntervalSince1970: 10)
        let candidates = [
            RecentSessionCandidate(id: "copilot", source: .githubCopilotCLI, agentKind: .githubCopilotCLI, title: "Copilot task", workingDirectory: "/", lastActiveAt: sameTime, resumeCommand: ["gh", "copilot"], summary: "", evidencePaths: [], confidence: 0.8),
            RecentSessionCandidate(id: "terminal", source: .shellHistory, agentKind: nil, title: "", workingDirectory: "/", lastActiveAt: sameTime, resumeCommand: ["bash"], summary: "", evidencePaths: [], confidence: 0.8),
            RecentSessionCandidate(id: "ignored", source: .shellHistory, agentKind: nil, title: "ignored", workingDirectory: "/ignored", lastActiveAt: nil, resumeCommand: ["bash"], summary: "", evidencePaths: [], confidence: 0.49)
        ]

        var proposal = WorkbenchImportProposalBuilder(maxSelectedPerGroup: 1, maxSelectedTotal: 1).build(candidates: candidates, now: sameTime)

        XCTAssertFalse(proposal.groups.isEmpty)
        XCTAssertEqual(proposal.ignoredCandidates.map(\.id), ["ignored"])
        XCTAssertTrue(proposal.groups.flatMap(\.terminals).contains { $0.name == "Copilot: Copilot task" })
        XCTAssertTrue(proposal.groups.flatMap(\.terminals).contains { $0.name == "Terminal: Session" })
        proposal.setSelection(groupID: "missing", selected: true)
        XCTAssertEqual(proposal.selectedTerminalCount, 1)
        XCTAssertEqual(WorkbenchImportProposalBuilder().slug("!!!"), "workbench-import")
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

    func testDeskBridgePlansAndSenseReadinessCopy() {
        let codex = DeskBridgePlanner().plan(agentName: "slugger", terminalKind: .openAICodex)
        XCTAssertEqual(codex.commandLine, "ouro setup --tool codex --agent slugger")
        XCTAssertNil(DeskBridgePlanner().plan(agentName: "slugger", terminalKind: .githubCopilotCLI).commandLine)
        XCTAssertNil(DeskBridgePlanner().plan(agentName: "slugger", terminalKind: .custom).setupCommand)

        let project = WorkbenchProject(name: "Empty", rootPath: temporaryDirectory.path)
        let readiness = OnboardingReadiness(state: .needsRepair, headline: "Repair", detail: "Detail", selectedBossName: "slugger", repairSteps: [])
        let rendered = WorkbenchSenseRenderer().render(
            state: WorkspaceState(boss: BossAgentSelection(agentName: "slugger"), projects: [project]),
            summary: WorkspaceSummary(boss: BossAgentSelection(agentName: "slugger"), processSnapshots: [], recoveryPlans: []),
            readiness: readiness
        )

        XCTAssertTrue(rendered.contains("readiness: needsRepair - Repair"))
        XCTAssertTrue(rendered.contains("- Empty: 0 active terminals"))
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

    func testOnboardingCoverageTargetedBranches() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let scanner = RecentSessionScanner(
            homeURL: temporaryDirectory,
            now: now,
            lookback: 7 * 24 * 60 * 60,
            sqlite3URL: temporaryDirectory.appendingPathComponent("missing-sqlite3"),
            liveProcessLister: {
                [RecentSessionScanner.LiveTerminalProcess(pid: 99, ttyName: nil, command: "claude --session-id live-nil-tty")]
            }
        )

        let old = RecentSessionCandidate(id: "old", source: .shellHistory, agentKind: nil, title: "Old", workingDirectory: "/old", lastActiveAt: Date(timeIntervalSince1970: 1), resumeCommand: ["bash"], summary: "", evidencePaths: [], confidence: 0.9)
        let undated = RecentSessionCandidate(id: "undated", source: .shellHistory, agentKind: nil, title: "Undated", workingDirectory: "/undated", lastActiveAt: nil, resumeCommand: ["bash"], summary: "", evidencePaths: [], confidence: 0.9)
        XCTAssertEqual(scanner.resolveRepositoryRoots([undated, old]).map(\.id), ["old", "undated"])

        let live = try XCTUnwrap(scanner.scanLiveClaudeCode().first)
        XCTAssertEqual(live.id, "claude:live-nil-tty")
        XCTAssertEqual(live.source, .claudeCode)

        let claudeURL = temporaryDirectory.appendingPathComponent(".claude/projects/plain-session/stale.jsonl")
        try FileManager.default.createDirectory(at: claudeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"sessionId":"stale","timestamp":"2020-01-01T00:00:00Z"}"#.write(to: claudeURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(scanner.scanClaudeCode().isEmpty)

        let malformed = temporaryDirectory.appendingPathComponent("malformed.jsonl")
        try #"not-json"#.write(to: malformed, atomically: true, encoding: .utf8)
        XCTAssertTrue(scanner.jsonLineObjects(malformed).isEmpty)
        XCTAssertNil(RecentSessionScanner.parseProcessLine("abc tty command"))
        XCTAssertNil(scanner.cleanedCmuxTitle(nil))
        XCTAssertEqual(WorkspaceGrouping.repositoryRoot(for: "/a/b") { _ in false }, nil)
    }

    func testImportProposalTieBreakersHomeDisplayAndSlugCollisions() {
        let sameTime = Date(timeIntervalSince1970: 123)
        let candidates = [
            RecentSessionCandidate(id: "z", source: .shellHistory, agentKind: nil, title: "Z", workingDirectory: "/", lastActiveAt: sameTime, resumeCommand: ["z"], summary: "", evidencePaths: [], confidence: 0.9, preferredGroupName: "Zoo"),
            RecentSessionCandidate(id: "a", source: .shellHistory, agentKind: nil, title: "A", workingDirectory: "/", lastActiveAt: sameTime, resumeCommand: ["a"], summary: "", evidencePaths: [], confidence: 0.9, preferredGroupName: "Alpha"),
            RecentSessionCandidate(id: "dup1", source: .shellHistory, agentKind: nil, title: "D1", workingDirectory: "/one", lastActiveAt: Date(timeIntervalSince1970: 1), resumeCommand: [], summary: "", evidencePaths: [], confidence: 0.9, preferredGroupName: "Dup"),
            RecentSessionCandidate(id: "dup2", source: .shellHistory, agentKind: nil, title: "D2", workingDirectory: "/two", lastActiveAt: Date(timeIntervalSince1970: 2), resumeCommand: [], summary: "", evidencePaths: [], confidence: 0.9, preferredGroupName: "Dup!"),
            RecentSessionCandidate(id: "dup3", source: .shellHistory, agentKind: nil, title: "D3", workingDirectory: "/three", lastActiveAt: Date(timeIntervalSince1970: 3), resumeCommand: [], summary: "", evidencePaths: [], confidence: 0.9, preferredGroupName: "Dup?"),
            RecentSessionCandidate(id: "home", source: .shellHistory, agentKind: nil, title: "Home", workingDirectory: "", lastActiveAt: Date(timeIntervalSince1970: 4), resumeCommand: [], summary: "", evidencePaths: [], confidence: 0.9)
        ]

        let builder = WorkbenchImportProposalBuilder(maxSelectedPerGroup: 3, maxSelectedTotal: 10)
        let proposal = builder.build(candidates: candidates, now: sameTime)
        let alphaIndex = proposal.groups.firstIndex { $0.name == "Alpha" }
        let zooIndex = proposal.groups.firstIndex { $0.name == "Zoo" }

        XCTAssertNotNil(alphaIndex)
        XCTAssertNotNil(zooIndex)
        XCTAssertLessThan(alphaIndex!, zooIndex!, "same-time groups should sort case-insensitively by name")
        XCTAssertTrue(proposal.groups.contains { $0.name == "Home" && $0.rootPath == "" })
        XCTAssertTrue(proposal.groups.map(\.id).contains("dup-3"))
        XCTAssertEqual(builder.displayName(for: ""), "Home")
        XCTAssertEqual(builder.workspaceRoot(for: "/Users/ari/Projects/App/Subdir/File"), "/Users/ari/Projects/App")
    }

    func testOnboardingAdditionalBranchCoverage() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let scanner = RecentSessionScanner(homeURL: temporaryDirectory, now: now, lookback: 7 * 24 * 60 * 60, sqlite3URL: temporaryDirectory.appendingPathComponent("missing"), liveProcessLister: { [] })

        let rightDated = RecentSessionCandidate(id: "right", source: .shellHistory, agentKind: nil, title: "right", workingDirectory: "/right", lastActiveAt: now, resumeCommand: [], summary: "", evidencePaths: [], confidence: 0.1)
        let leftNil = RecentSessionCandidate(id: "left", source: .shellHistory, agentKind: nil, title: "left", workingDirectory: "/left", lastActiveAt: nil, resumeCommand: [], summary: "", evidencePaths: [], confidence: 0.99)
        XCTAssertEqual(scanner.resolveRepositoryRoots([leftNil, rightDated]).first?.id, "right")

        let fileRoot = temporaryDirectory.appendingPathComponent("not-a-directory")
        try "file".write(to: fileRoot, atomically: true, encoding: .utf8)
        XCTAssertTrue(scanner.recentFiles(under: fileRoot, pathExtension: "jsonl").isEmpty)

        let claudeURL = temporaryDirectory.appendingPathComponent(".claude/projects/-Users-ari-home/defaults.jsonl")
        try FileManager.default.createDirectory(at: claudeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"sessionId":"defaulted","timestamp":"not a date"}"#.write(to: claudeURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: claudeURL.path)
        let claude = try XCTUnwrap(scanner.scanClaudeCode().first { $0.id == "claude:defaulted" })
        XCTAssertEqual(claude.summary, "Recent Claude Code session.")
        XCTAssertEqual(claude.lastActiveAt, now)

        let historyURL = temporaryDirectory.appendingPathComponent(".zsh_history")
        try [
            ": 1779796800:0;claude --session-id shell-claude",
            ": 1779796800:0;gh copilot explain this | cat"
        ].joined(separator: "\n").write(to: historyURL, atomically: true, encoding: .utf8)
        let shellCandidates = scanner.scanShellHistory()
        XCTAssertTrue(shellCandidates.contains { $0.source == .shellHistory && $0.agentKind == .claudeCode })
        XCTAssertTrue(shellCandidates.contains { $0.source == .githubCopilotCLI && $0.agentKind == .githubCopilotCLI && $0.resumeCommand == ["gh", "copilot", "explain", "this", "|", "cat"] })

        let codexURL = temporaryDirectory.appendingPathComponent(".codex/state_5.sqlite")
        try FileManager.default.createDirectory(at: codexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: codexURL.path, contents: Data())
        let sqliteDir = temporaryDirectory.appendingPathComponent("sqlite-as-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: sqliteDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sqliteDir.path)
        XCTAssertTrue(RecentSessionScanner(homeURL: temporaryDirectory, now: now, sqlite3URL: sqliteDir, liveProcessLister: { [] }).scanCodex().isEmpty)
    }

    func testCmuxSkipsClaudeProcessWithoutSessionAndReadsSparseJSON() throws {
        let cmuxURL = temporaryDirectory.appendingPathComponent("cmux-sparse.json")
        try """
        {"windows":[{"tabManager":{"workspaces":[{"panels":[{"ttyName":"ttys011"}]}]}}]}
        """.write(to: cmuxURL, atomically: true, encoding: .utf8)
        let scanner = RecentSessionScanner(
            homeURL: temporaryDirectory,
            cmuxSessionURL: cmuxURL,
            liveProcessLister: {
                [RecentSessionScanner.LiveTerminalProcess(pid: 11, ttyName: "ttys011", command: "claude")]
            }
        )

        XCTAssertTrue(scanner.scanCmuxSessions().isEmpty)
    }

    func testRendererAndWorkbenchFallbackCopyBranches() {
        let rendered = OnboardingReadinessReportRenderer().render(OnboardingReadiness(
            state: .ready,
            headline: "Ready",
            detail: "All set",
            selectedBossName: "slugger",
            repairSteps: [OnboardingRepairStep(id: "manual", actor: .humanChoice, title: "Manual", detail: "No command")]
        ))
        XCTAssertTrue(rendered.contains("- none"))

        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let entry = ProcessEntry(projectId: project.id, name: "Bare", kind: .terminalAgent, executable: "/bin/zsh", workingDirectory: "/repo")
        let candidate = RecentSessionScanner(homeURL: temporaryDirectory).scanWorkbench(state: WorkspaceState(projects: [project], processEntries: [entry])).first
        XCTAssertEqual(candidate?.summary, "Existing Workbench terminal.")
    }

    func testImportProposalNilDateFallbackOrdering() {
        let candidates = [
            RecentSessionCandidate(id: "b", source: .shellHistory, agentKind: nil, title: "B", workingDirectory: "/b", lastActiveAt: nil, resumeCommand: [], summary: "", evidencePaths: [], confidence: 0.9, repositoryRoot: "/b"),
            RecentSessionCandidate(id: "a", source: .shellHistory, agentKind: nil, title: "A", workingDirectory: "/a", lastActiveAt: nil, resumeCommand: [], summary: "", evidencePaths: [], confidence: 0.9, repositoryRoot: "/a")
        ]
        let proposal = WorkbenchImportProposalBuilder().build(candidates: candidates)
        XCTAssertEqual(proposal.groups.map(\.name), ["a", "b"])
        XCTAssertEqual(proposal.groups.first?.terminals.map(\.id), ["a"])
    }

    func testOnboardingRefactorBranchesForSparseInputs() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let emptyCmux = temporaryDirectory.appendingPathComponent("empty-cmux.json")
        try "{}".write(to: emptyCmux, atomically: true, encoding: .utf8)
        let nilTTYScanner = RecentSessionScanner(
            homeURL: temporaryDirectory,
            now: now,
            sqlite3URL: temporaryDirectory.appendingPathComponent("missing"),
            cmuxSessionURL: emptyCmux,
            liveProcessLister: {
                [RecentSessionScanner.LiveTerminalProcess(pid: 22, ttyName: nil, command: "claude --session-id no-tty")]
            }
        )
        XCTAssertTrue(nilTTYScanner.scanCmuxSessions().isEmpty)

        let historyURL = temporaryDirectory.appendingPathComponent(".zsh_history")
        try ": 1779796800:0;foo && gh copilot explain issue\n".write(to: historyURL, atomically: true, encoding: .utf8)
        let shell = RecentSessionScanner(homeURL: temporaryDirectory, now: now, sqlite3URL: temporaryDirectory.appendingPathComponent("missing"), liveProcessLister: { [] }).scanShellHistory()
        XCTAssertTrue(shell.contains { $0.source == .githubCopilotCLI && $0.resumeCommand.contains("&&") })

        let codexURL = temporaryDirectory.appendingPathComponent(".codex/state_5.sqlite")
        try FileManager.default.createDirectory(at: codexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: codexURL.path, contents: Data())
        let sqliteURL = temporaryDirectory.appendingPathComponent("sqlite-invalid-ms")
        try "#!/bin/sh\nprintf 'codex-badms\\tBad milliseconds\\t/repo\\tmain\\toops\\n'\n"
            .write(to: sqliteURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sqliteURL.path)
        let codex = RecentSessionScanner(homeURL: temporaryDirectory, now: now, sqlite3URL: sqliteURL, liveProcessLister: { [] }).scanCodex()
        XCTAssertEqual(codex.first?.lastActiveAt, nil)
    }

    func testOnboardingBigFileFinalCoverageBranches() throws {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let scanner = RecentSessionScanner(
            homeURL: temporaryDirectory,
            now: now,
            lookback: 7 * 24 * 60 * 60,
            sqlite3URL: temporaryDirectory.appendingPathComponent("missing"),
            liveProcessLister: { [] },
            commandParser: TerminalCommandParser.parse
        )

        let emptyReadiness = OnboardingReadiness(
            state: .ready,
            headline: "Ready",
            detail: "No action",
            selectedBossName: "slugger",
            repairSteps: []
        )
        XCTAssertTrue(OnboardingReadinessReportRenderer().render(emptyReadiness).contains("repair steps: none"))

        let nilDate = RecentSessionCandidate(id: "nil", source: .shellHistory, agentKind: nil, title: "nil", workingDirectory: "/nil", lastActiveAt: nil, resumeCommand: [], summary: "", evidencePaths: [], confidence: 0.8)
        let dated = RecentSessionCandidate(id: "dated", source: .shellHistory, agentKind: nil, title: "dated", workingDirectory: "/dated", lastActiveAt: now, resumeCommand: [], summary: "", evidencePaths: [], confidence: 0.7)
        let newer = RecentSessionCandidate(id: "newer", source: .shellHistory, agentKind: nil, title: "newer", workingDirectory: "/newer", lastActiveAt: now.addingTimeInterval(1), resumeCommand: [], summary: "", evidencePaths: [], confidence: 0.6)
        XCTAssertEqual(scanner.resolveRepositoryRoots([nilDate, dated, newer]).map(\.id), ["newer", "dated", "nil"])
        for ordering in [[nilDate, dated], [dated, nilDate], [nilDate, newer, dated], [dated, newer, nilDate]] {
            XCTAssertEqual(scanner.resolveRepositoryRoots(ordering).last?.id, "nil")
        }

        let historyURL = temporaryDirectory.appendingPathComponent(".zsh_history")
        try ": 1779796800:0;gh copilot explain 'unterminated\n"
            .write(to: historyURL, atomically: true, encoding: .utf8)
        let nilParsingScanner = RecentSessionScanner(
            homeURL: temporaryDirectory,
            now: now,
            lookback: 7 * 24 * 60 * 60,
            sqlite3URL: temporaryDirectory.appendingPathComponent("missing"),
            liveProcessLister: { [] },
            commandParser: { _ in nil }
        )
        let fallback = try XCTUnwrap(nilParsingScanner.scanShellHistory().first)
        XCTAssertEqual(fallback.resumeCommand, ["gh", "copilot", "explain", "'unterminated"])

        let brokenSymlink = temporaryDirectory.appendingPathComponent("broken-symlink")
        try FileManager.default.createSymbolicLink(
            at: brokenSymlink,
            withDestinationURL: temporaryDirectory.appendingPathComponent("missing-target")
        )
        XCTAssertTrue(scanner.recentFiles(under: brokenSymlink, pathExtension: "jsonl").isEmpty)
        XCTAssertTrue(scanner.recentFiles(under: URL(string: "not-file://missing")!, pathExtension: "jsonl").isEmpty)
        XCTAssertTrue(scanner.recentFiles(under: temporaryDirectory, pathExtension: "jsonl", makeEnumerator: { _ in nil }).isEmpty)

        let homeClaudeURL = temporaryDirectory.appendingPathComponent(".claude/projects/plain/default-home.jsonl")
        try FileManager.default.createDirectory(at: homeClaudeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"sessionId":"default-home","timestamp":"2026-05-26T11:00:00Z"}"#
            .write(to: homeClaudeURL, atomically: true, encoding: .utf8)
        let homeClaude = try XCTUnwrap(scanner.scanClaudeCode().first { $0.id == "claude:default-home" })
        XCTAssertEqual(homeClaude.workingDirectory, temporaryDirectory.path)
        XCTAssertEqual(homeClaude.confidence, 0.72)

        let historyCandidate = RecentSessionCandidate(
            id: "claude:with-history",
            source: .claudeCode,
            agentKind: .claudeCode,
            title: "History title",
            workingDirectory: "/history",
            lastActiveAt: now,
            resumeCommand: ["claude"],
            summary: "History summary",
            evidencePaths: ["history.jsonl"],
            confidence: 0.9
        )
        let liveWithHistory = scanner.scanLiveClaudeCode(
            liveProcesses: [RecentSessionScanner.LiveTerminalProcess(pid: 42, ttyName: "ttys042", command: "claude --session-id with-history")],
            claudeHistory: [historyCandidate]
        ).first
        XCTAssertEqual(liveWithHistory?.confidence, 0.95)
        XCTAssertEqual(liveWithHistory?.evidencePaths, ["history.jsonl", "process:42"])

        XCTAssertTrue(RecentSessionScanner.systemLiveTerminalProcesses(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: []
        ).isEmpty)
        XCTAssertTrue(RecentSessionScanner.systemLiveTerminalProcesses(
            executableURL: temporaryDirectory.appendingPathComponent("missing-ps"),
            arguments: []
        ).isEmpty)

        let cmuxURL = temporaryDirectory.appendingPathComponent("cmux-no-panels.json")
        try #"{"windows":[{"tabManager":{"workspaces":[{"statusEntries":[]}]}}]}"#
            .write(to: cmuxURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(RecentSessionScanner(
            homeURL: temporaryDirectory,
            cmuxSessionURL: cmuxURL,
            liveProcessLister: { [] }
        ).scanCmuxSessions().isEmpty)

        let cmuxFallbackURL = temporaryDirectory.appendingPathComponent("cmux-summary-fallback.json")
        try """
        {"windows":[{"tabManager":{"workspaces":[{"panels":[{"ttyName":"ttys012"}]}]}}]}
        """.write(to: cmuxFallbackURL, atomically: true, encoding: .utf8)
        let cmuxFallback = try XCTUnwrap(RecentSessionScanner(
            homeURL: temporaryDirectory,
            cmuxSessionURL: cmuxFallbackURL,
            liveProcessLister: {
                [RecentSessionScanner.LiveTerminalProcess(pid: 12, ttyName: "ttys012", command: "claude --session-id cmux-summary")]
            }
        ).scanCmuxSessions().first)
        XCTAssertEqual(cmuxFallback.summary, "Live cmux Claude Code panel in cmux.")
        XCTAssertTrue(cmuxFallback.evidencePaths.contains("tty:ttys012"))

        let longPath = "/" + (1...70).map { "d\($0)" }.joined(separator: "/")
        XCTAssertNil(WorkspaceGrouping.repositoryRoot(for: longPath) { _ in false })

        let sameRootNilDates = [
            RecentSessionCandidate(id: "b", source: .shellHistory, agentKind: nil, title: "B", workingDirectory: "/repo/b", lastActiveAt: nil, resumeCommand: [], summary: "", evidencePaths: [], confidence: 0.9, repositoryRoot: "/repo"),
            RecentSessionCandidate(id: "a", source: .shellHistory, agentKind: nil, title: "A", workingDirectory: "/repo/a", lastActiveAt: nil, resumeCommand: [], summary: "", evidencePaths: [], confidence: 0.9, repositoryRoot: "/repo")
        ]
        let proposal = WorkbenchImportProposalBuilder().build(candidates: sameRootNilDates, now: now)
        XCTAssertEqual(proposal.groups.first?.terminals.map(\.id), ["b", "a"])

        let namedNoRoot = RecentSessionCandidate(id: "named", source: .shellHistory, agentKind: nil, title: "Named", workingDirectory: "/named/work", lastActiveAt: now, resumeCommand: [], summary: "", evidencePaths: [], confidence: 0.9, preferredGroupName: "Named Group")
        let namedProposal = WorkbenchImportProposalBuilder().build(candidates: [namedNoRoot], now: now)
        XCTAssertEqual(namedProposal.groups.first?.rootPath, "/named/work")
    }

    func testCodexSQLiteScannerTerminatesHungSQLiteProcess() throws {
        let codexURL = temporaryDirectory.appendingPathComponent(".codex/state_5.sqlite")
        try FileManager.default.createDirectory(at: codexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: codexURL.path, contents: Data())

        let sqliteURL = temporaryDirectory.appendingPathComponent("sqlite-hangs")
        try "#!/bin/sh\nsleep 300\n"
            .write(to: sqliteURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sqliteURL.path)

        let scanner = RecentSessionScanner(
            homeURL: temporaryDirectory,
            sqlite3URL: sqliteURL,
            liveProcessLister: { [] },
            codexSQLiteWatchdogDelay: 0.01
        )

        XCTAssertTrue(scanner.scanCodex().isEmpty)
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
