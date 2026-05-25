import Foundation

public struct WorkbenchScenarioMatrix: Sendable {
    public static let expectedHeader = [
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

    public var rows: [WorkbenchScenarioRow]

    public init(rows: [WorkbenchScenarioRow]) {
        self.rows = rows
    }

    public static func load(from url: URL) throws -> WorkbenchScenarioMatrix {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else {
            throw WorkbenchScenarioMatrixError.emptyMatrix
        }
        let header = lines.removeFirst().split(separator: "\t").map(String.init)
        guard header == expectedHeader else {
            throw WorkbenchScenarioMatrixError.invalidHeader(header)
        }
        let rows = try lines.enumerated().map { offset, line in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return try WorkbenchScenarioRow(columns: columns, lineNumber: offset + 2)
        }
        return WorkbenchScenarioMatrix(rows: rows)
    }

    public static func defaultMatrixURL(packageRoot: URL) -> URL {
        packageRoot
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("workbench-5000-scenario-matrix.tsv")
    }

    public func fixture(for row: WorkbenchScenarioRow) throws -> WorkbenchScenarioFixture {
        let project = WorkbenchProject(
            id: stableUUID("00000000-0000-0000-0000-000000000001"),
            name: "Matrix",
            rootPath: "/tmp/workbench-matrix"
        )
        let posture = try WorkbenchTrustResumePosture(rawValue: row.trustResumeMetadata)
        let surface = try WorkbenchSurfacePosture(rawValue: row.surface)
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

        return WorkbenchScenarioFixture(
            entry: entry,
            latestRun: runs.first,
            state: state,
            executableHealth: [entry.id: health],
            bossWatchEnabled: surface.bossWatchEnabled
        )
    }

    public func registration(for row: WorkbenchScenarioRow) -> BossWorkbenchMCPRegistrationSnapshot {
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

    private func makeEntry(
        row: WorkbenchScenarioRow,
        projectId: UUID,
        posture: WorkbenchTrustResumePosture,
        surface: WorkbenchSurfacePosture
    ) throws -> ProcessEntry {
        switch row.terminal {
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
            throw WorkbenchScenarioMatrixError.invalidValue("terminal \(row.terminal)")
        }
    }

    private func makeRun(
        row: WorkbenchScenarioRow,
        entry: ProcessEntry,
        posture: WorkbenchTrustResumePosture
    ) throws -> ProcessRun? {
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
            throw WorkbenchScenarioMatrixError.invalidValue("lifecycle \(row.lifecycle)")
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

    private func stableUUID(_ raw: String) -> UUID {
        UUID(uuidString: raw)!
    }
}

public struct WorkbenchScenarioRow: Equatable, Sendable {
    public var caseID: String
    public var terminal: String
    public var lifecycle: String
    public var trustResumeMetadata: String
    public var surface: String
    public var bossBridge: String
    public var executableHealth: String
    public var expectedRecovery: String
    public var expectedRecoveryPrompt: Bool
    public var expectedReadiness: String
    public var optimalOperatorOutcome: String
    public var optimalBossOutcome: String

    public init(columns: [String], lineNumber: Int) throws {
        guard columns.count == WorkbenchScenarioMatrix.expectedHeader.count else {
            throw WorkbenchScenarioMatrixError.invalidColumnCount(line: lineNumber, count: columns.count)
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

public struct WorkbenchScenarioFixture: Sendable {
    public var entry: ProcessEntry
    public var latestRun: ProcessRun?
    public var state: WorkspaceState
    public var executableHealth: [UUID: ExecutableHealth]
    public var bossWatchEnabled: Bool

    public init(
        entry: ProcessEntry,
        latestRun: ProcessRun?,
        state: WorkspaceState,
        executableHealth: [UUID: ExecutableHealth],
        bossWatchEnabled: Bool
    ) {
        self.entry = entry
        self.latestRun = latestRun
        self.state = state
        self.executableHealth = executableHealth
        self.bossWatchEnabled = bossWatchEnabled
    }
}

public struct WorkbenchTrustResumePosture: Equatable, Sendable {
    public var trust: ProcessTrust
    public var autoResume: Bool
    public var hasSessionMetadata: Bool

    public init(rawValue: String) throws {
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
            throw WorkbenchScenarioMatrixError.invalidValue("trust_resume_metadata \(rawValue)")
        }
    }
}

public struct WorkbenchSurfacePosture: Equatable, Sendable {
    public var isArchived: Bool
    public var bossWatchEnabled: Bool

    public init(rawValue: String) throws {
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
            throw WorkbenchScenarioMatrixError.invalidValue("surface \(rawValue)")
        }
    }
}

public enum WorkbenchScenarioMatrixError: Error, CustomStringConvertible, Equatable {
    case emptyMatrix
    case invalidHeader([String])
    case invalidColumnCount(line: Int, count: Int)
    case invalidValue(String)

    public var description: String {
        switch self {
        case .emptyMatrix:
            return "scenario matrix is empty"
        case let .invalidHeader(header):
            return "invalid matrix header: \(header.joined(separator: ","))"
        case let .invalidColumnCount(line, count):
            return "line \(line) has \(count) columns"
        case let .invalidValue(value):
            return "invalid matrix value: \(value)"
        }
    }
}
