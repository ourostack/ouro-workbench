import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchScenarioMatrixTests: XCTestCase {
    func testScenarioMatrixContainsExactlyFiveThousandCasesWithOptimalOutcomes() throws {
        let rows = try loadRows()

        XCTAssertEqual(rows.count, 5_000)
        XCTAssertEqual(Set(rows.map(\.caseID)).count, 5_000)
        XCTAssertEqual(rows.first?.caseID, "WB-0001")
        XCTAssertEqual(rows.last?.caseID, "WB-5000")

        let emptyOutcomeRows = rows.filter {
            $0.optimalOperatorOutcome.isEmpty || $0.optimalBossOutcome.isEmpty
        }
        XCTAssertTrue(emptyOutcomeRows.isEmpty, "Rows missing outcomes: \(emptyOutcomeRows.prefix(10).map(\.caseID))")
    }

    func testAllFiveThousandScenarioRowsMatchRecoveryReadinessAndCommandPlanning() throws {
        let rows = try loadRows()
        let summarizer = WorkspaceSummarizer()
        let readinessBuilder = AutonomyReadinessBuilder()
        let commandPlanner = WorkbenchCommandPlanner()
        var mismatches: [String] = []

        for row in rows {
            let fixture = try fixture(for: row)
            let actualRecovery = RecoveryPlanner()
                .planRecovery(for: fixture.entry, latestRun: fixture.latestRun)
                .action
                .rawValue
            if actualRecovery != row.expectedRecovery {
                mismatches.append("\(row.caseID): recovery expected \(row.expectedRecovery), got \(actualRecovery)")
            }

            let snapshot = readinessBuilder.build(
                state: fixture.state,
                summary: summarizer.summarize(fixture.state),
                mcpRegistration: registration(for: row),
                executableHealth: fixture.executableHealth,
                bossWatchIsEnabled: fixture.bossWatchEnabled
            )
            let actualReadiness = snapshot.state.rawValue
            if actualReadiness != row.expectedReadiness {
                mismatches.append("\(row.caseID): readiness expected \(row.expectedReadiness), got \(actualReadiness)")
            }

            let planned = try commandPlanner.recoveryPlan(
                for: fixture.entry,
                latestRun: fixture.latestRun,
                action: RecoveryAction(rawValue: row.expectedRecovery) ?? .noAction
            )
            let includesCheckpointPrompt = planned.arguments.contains {
                $0.contains("Recover this Ouro Workbench terminal-agent session")
            }
            if includesCheckpointPrompt != row.expectedRecoveryPrompt {
                mismatches.append(
                    "\(row.caseID): checkpoint prompt expected \(row.expectedRecoveryPrompt), got \(includesCheckpointPrompt)"
                )
            }

            if mismatches.count >= 20 {
                break
            }
        }

        XCTAssertTrue(mismatches.isEmpty, mismatches.joined(separator: "\n"))
    }

    private func loadRows() throws -> [ScenarioRow] {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let url = packageRoot
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("workbench-5000-scenario-matrix.tsv")
        let contents = try String(contentsOf: url, encoding: .utf8)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let header = lines.removeFirst().split(separator: "\t").map(String.init)
        XCTAssertEqual(header, ScenarioRow.expectedHeader)
        return try lines.enumerated().map { offset, line in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return try ScenarioRow(columns: columns, lineNumber: offset + 2)
        }
    }

    private func fixture(for row: ScenarioRow) throws -> ScenarioFixture {
        let project = WorkbenchProject(
            id: stableUUID("00000000-0000-0000-0000-000000000001"),
            name: "Matrix",
            rootPath: "/tmp/workbench-matrix"
        )
        let posture = try TrustResumePosture(rawValue: row.trustResumeMetadata)
        let surface = try SurfacePosture(rawValue: row.surface)
        var entry = try makeEntry(row: row, projectId: project.id, posture: posture, surface: surface)
        var runs: [ProcessRun] = []

        if let run = try makeRun(row: row, entry: entry, posture: posture) {
            runs.append(run)
            if row.lifecycle == "waiting_for_input" {
                entry.attention = .waitingOnHuman
            }
        }

        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "slugger", scope: "machine"),
            bossWatchEnabled: surface.bossWatchEnabled,
            bossPaneCollapsed: row.surface == "boss_pane_collapsed",
            selectedProjectId: project.id,
            selectedEntryId: entry.id,
            projects: [project],
            processEntries: [entry],
            processRuns: runs
        )

        let health = ExecutableHealth(
            executable: ExecutableHealthTarget.executable(for: entry),
            resolvedPath: row.executableHealth == "available" ? "/usr/bin/\(entry.executable)" : nil,
            status: row.executableHealth == "available" ? .available : .missing,
            detail: row.executableHealth == "available" ? "Found command." : "Command missing."
        )

        return ScenarioFixture(
            entry: entry,
            latestRun: runs.first,
            state: state,
            executableHealth: [entry.id: health],
            bossWatchEnabled: surface.bossWatchEnabled
        )
    }

    private func makeEntry(
        row: ScenarioRow,
        projectId: UUID,
        posture: TrustResumePosture,
        surface: SurfacePosture
    ) throws -> ProcessEntry {
        let terminal = row.terminal
        let commonName = terminal.replacingOccurrences(of: "_", with: " ").capitalized
        switch terminal {
        case "claude":
            return ProcessEntry(
                id: stableUUID("10000000-0000-0000-0000-000000000001"),
                projectId: projectId,
                name: "Claude",
                kind: .terminalAgent,
                agentKind: .claudeCode,
                executable: "claude",
                arguments: ["--dangerously-skip-permissions"],
                workingDirectory: "/tmp/workbench-matrix",
                trust: posture.trust,
                autoResume: posture.autoResume,
                isArchived: surface.isArchived
            )
        case "codex":
            return ProcessEntry(
                id: stableUUID("10000000-0000-0000-0000-000000000002"),
                projectId: projectId,
                name: "Codex",
                kind: .terminalAgent,
                agentKind: .openAICodex,
                executable: "codex",
                arguments: ["--yolo"],
                workingDirectory: "/tmp/workbench-matrix",
                trust: posture.trust,
                autoResume: posture.autoResume,
                isArchived: surface.isArchived
            )
        case "copilot":
            return ProcessEntry(
                id: stableUUID("10000000-0000-0000-0000-000000000003"),
                projectId: projectId,
                name: "Copilot",
                kind: .terminalAgent,
                agentKind: .githubCopilotCLI,
                executable: "gh",
                arguments: ["copilot", "--", "--yolo"],
                workingDirectory: "/tmp/workbench-matrix",
                trust: posture.trust,
                autoResume: posture.autoResume,
                isArchived: surface.isArchived
            )
        case "generic_tui":
            return ProcessEntry(
                id: stableUUID("10000000-0000-0000-0000-000000000004"),
                projectId: projectId,
                name: "Generic TUI",
                kind: .terminalAgent,
                executable: "/bin/zsh",
                arguments: ["-lc", "aider --yes"],
                workingDirectory: "/tmp/workbench-matrix",
                trust: posture.trust,
                autoResume: posture.autoResume,
                isArchived: surface.isArchived
            )
        case "local_shell":
            return ProcessEntry(
                id: stableUUID("10000000-0000-0000-0000-000000000005"),
                projectId: projectId,
                name: "Local Shell",
                kind: .shell,
                executable: "/bin/zsh",
                arguments: ["-l"],
                workingDirectory: "/tmp/workbench-matrix",
                trust: posture.trust,
                autoResume: posture.autoResume,
                isArchived: surface.isArchived
            )
        default:
            throw MatrixError.invalidValue("terminal \(commonName)")
        }
    }

    private func makeRun(row: ScenarioRow, entry: ProcessEntry, posture: TrustResumePosture) throws -> ProcessRun? {
        let status: ProcessStatus
        switch row.lifecycle {
        case "configured":
            return nil
        case "running":
            status = .running
        case "waiting_for_input":
            status = .waitingForInput
        case "needs_recovery":
            status = .needsRecovery
        case "manual_action_needed":
            status = .manualActionNeeded
        default:
            throw MatrixError.invalidValue("lifecycle \(row.lifecycle)")
        }

        return ProcessRun(
            id: stableUUID("20000000-0000-0000-0000-000000000001"),
            entryId: entry.id,
            pid: status == .running ? 42 : nil,
            status: status,
            terminalSessionId: posture.hasSessionMetadata ? "matrix-session-\(entry.id.uuidString)" : nil,
            transcriptPath: "/tmp/workbench-matrix/transcript.log"
        )
    }

    private func registration(for row: ScenarioRow) -> BossWorkbenchMCPRegistrationSnapshot {
        let status: BossWorkbenchMCPRegistrationStatus
        switch row.bossBridge {
        case "registered":
            status = .registered
        case "not_registered":
            status = .notRegistered
        case "needs_update":
            status = .needsUpdate
        case "agent_missing":
            status = .agentMissing
        default:
            status = .invalidConfig
        }
        return BossWorkbenchMCPRegistrationSnapshot(
            agentName: "slugger",
            serverName: "ouro_workbench",
            commandPath: "/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP",
            agentConfigPath: "/Users/ari/AgentBundles/slugger.ouro/agent.json",
            status: status,
            detail: status.rawValue
        )
    }

    private func stableUUID(_ raw: String) -> UUID {
        UUID(uuidString: raw)!
    }
}

private struct ScenarioRow {
    static let expectedHeader = [
        "case_id",
        "terminal",
        "lifecycle",
        "trust_resume_metadata",
        "surface",
        "boss_bridge",
        "executable_health",
        "expected_recovery",
        "expected_recovery_prompt",
        "expected_readiness",
        "optimal_operator_outcome",
        "optimal_boss_outcome"
    ]

    var caseID: String
    var terminal: String
    var lifecycle: String
    var trustResumeMetadata: String
    var surface: String
    var bossBridge: String
    var executableHealth: String
    var expectedRecovery: String
    var expectedRecoveryPrompt: Bool
    var expectedReadiness: String
    var optimalOperatorOutcome: String
    var optimalBossOutcome: String

    init(columns: [String], lineNumber: Int) throws {
        guard columns.count == Self.expectedHeader.count else {
            throw MatrixError.invalidColumnCount(line: lineNumber, count: columns.count)
        }
        self.caseID = columns[0]
        self.terminal = columns[1]
        self.lifecycle = columns[2]
        self.trustResumeMetadata = columns[3]
        self.surface = columns[4]
        self.bossBridge = columns[5]
        self.executableHealth = columns[6]
        self.expectedRecovery = columns[7]
        self.expectedRecoveryPrompt = columns[8] == "true"
        self.expectedReadiness = columns[9]
        self.optimalOperatorOutcome = columns[10]
        self.optimalBossOutcome = columns[11]
    }
}

private struct ScenarioFixture {
    var entry: ProcessEntry
    var latestRun: ProcessRun?
    var state: WorkspaceState
    var executableHealth: [UUID: ExecutableHealth]
    var bossWatchEnabled: Bool
}

private struct TrustResumePosture {
    var trust: ProcessTrust
    var autoResume: Bool
    var hasSessionMetadata: Bool

    init(rawValue: String) throws {
        switch rawValue {
        case "trusted_auto_session":
            self.trust = .trusted
            self.autoResume = true
            self.hasSessionMetadata = true
        case "trusted_auto_no_session":
            self.trust = .trusted
            self.autoResume = true
            self.hasSessionMetadata = false
        case "trusted_no_auto":
            self.trust = .trusted
            self.autoResume = false
            self.hasSessionMetadata = true
        case "untrusted_auto":
            self.trust = .untrusted
            self.autoResume = true
            self.hasSessionMetadata = true
        case "untrusted_no_auto":
            self.trust = .untrusted
            self.autoResume = false
            self.hasSessionMetadata = false
        default:
            throw MatrixError.invalidValue("trust_resume_metadata \(rawValue)")
        }
    }
}

private struct SurfacePosture {
    var isArchived: Bool
    var bossWatchEnabled: Bool

    init(rawValue: String) throws {
        switch rawValue {
        case "sidebar_dashboard", "sidebar_hidden_dashboard", "terminal_focus":
            self.isArchived = false
            self.bossWatchEnabled = true
        case "boss_pane_collapsed":
            self.isArchived = false
            self.bossWatchEnabled = false
        case "archived_session":
            self.isArchived = true
            self.bossWatchEnabled = true
        default:
            throw MatrixError.invalidValue("surface \(rawValue)")
        }
    }
}

private enum MatrixError: Error, CustomStringConvertible {
    case invalidColumnCount(line: Int, count: Int)
    case invalidValue(String)

    var description: String {
        switch self {
        case let .invalidColumnCount(line, count):
            return "line \(line) has \(count) columns"
        case let .invalidValue(value):
            return "invalid matrix value: \(value)"
        }
    }
}
