import AppKit
import Foundation
import OuroWorkbenchCore

@main
struct OuroWorkbenchScenarioVerifierCommand {
    static func main() throws {
        let options = try ScenarioVerifierOptions(arguments: Array(CommandLine.arguments.dropFirst()))
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let matrixURL = options.matrixURL ?? WorkbenchScenarioMatrix.defaultMatrixURL(packageRoot: packageRoot)
        let outputDirectory = options.outputDirectory ?? packageRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("workbench-scenario-verifier", isDirectory: true)

        let matrix = try WorkbenchScenarioMatrix.load(from: matrixURL)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let verifier = NativeScenarioVerifier(
            outputDirectory: outputDirectory,
            writeSamples: options.writeSamples,
            sampleLimit: options.sampleLimit,
            maxRows: options.maxRows,
            deepScenarioCount: options.deepScenarioCount,
            deepSeed: options.deepSeed
        )
        let summary = try verifier.verify(matrix: matrix)
        try summary.write(to: outputDirectory.appendingPathComponent("summary.json"))

        print(summary.consoleSummary)
        if !summary.failures.isEmpty {
            for failure in summary.failures.prefix(25) {
                print("failure: \(failure.caseID) [\(failure.viewport)] \(failure.message)")
            }
            Darwin.exit(1)
        }
    }
}

struct ScenarioVerifierOptions {
    var matrixURL: URL?
    var outputDirectory: URL?
    var writeSamples = true
    var sampleLimit = 20
    var maxRows: Int?
    var deepScenarioCount = 0
    var deepSeed: UInt64 = 0x0F00_DF00_D202_60525

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--matrix":
                index += 1
                matrixURL = URL(fileURLWithPath: try Self.value(after: argument, in: arguments, at: index))
            case "--out":
                index += 1
                outputDirectory = URL(fileURLWithPath: try Self.value(after: argument, in: arguments, at: index), isDirectory: true)
            case "--no-samples":
                writeSamples = false
            case "--sample-limit":
                index += 1
                sampleLimit = Int(try Self.value(after: argument, in: arguments, at: index)) ?? sampleLimit
            case "--max-rows":
                index += 1
                maxRows = Int(try Self.value(after: argument, in: arguments, at: index))
            case "--deep-scenarios":
                index += 1
                deepScenarioCount = Int(try Self.value(after: argument, in: arguments, at: index)) ?? deepScenarioCount
            case "--seed":
                index += 1
                deepSeed = UInt64(try Self.value(after: argument, in: arguments, at: index)) ?? deepSeed
            case "--help", "-h":
                Self.printHelp()
                Darwin.exit(0)
            default:
                throw ScenarioVerifierError.invalidArgument(argument)
            }
            index += 1
        }
    }

    private static func value(after argument: String, in arguments: [String], at index: Int) throws -> String {
        guard index < arguments.count else {
            throw ScenarioVerifierError.missingValue(argument)
        }
        return arguments[index]
    }

    private static func printHelp() {
        print("""
        Usage: swift run OuroWorkbenchScenarioVerifier [options]

        Options:
          --matrix PATH        Scenario TSV path. Defaults to docs/workbench-5000-scenario-matrix.tsv.
          --out PATH           Output directory. Defaults to .build/workbench-scenario-verifier.
          --no-samples         Do not write PNG sample evidence.
          --sample-limit N     Maximum sample PNGs to write. Defaults to 20.
          --max-rows N         Limit rows for local debugging.
          --deep-scenarios N   Add N deterministic generated scenarios after the matrix.
          --seed N             Seed for generated deep scenarios.
        """)
    }
}

struct NativeScenarioVerifier {
    var outputDirectory: URL
    var writeSamples: Bool
    var sampleLimit: Int
    var maxRows: Int?
    var deepScenarioCount: Int
    var deepSeed: UInt64

    private let summarizer = WorkspaceSummarizer()
    private let readinessBuilder = AutonomyReadinessBuilder()
    private let commandPlanner = WorkbenchCommandPlanner()
    private let recoveryPlanner = RecoveryPlanner()
    private let viewports = [
        ScenarioViewport(name: "standard", width: 1200, height: 760),
        ScenarioViewport(name: "short-window", width: 640, height: 420),
        ScenarioViewport(name: "compact-terminal", width: 520, height: 360),
        ScenarioViewport(name: "tall-workspace", width: 900, height: 1000),
        ScenarioViewport(name: "wide-workspace", width: 1600, height: 900)
    ]

    func verify(matrix: WorkbenchScenarioMatrix) throws -> ScenarioVerifierSummary {
        let sampleDirectory = outputDirectory.appendingPathComponent("samples", isDirectory: true)
        if writeSamples {
            try FileManager.default.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)
        }

        var rowsVerified = 0
        var renderPasses = 0
        var failures: [ScenarioVerifierFailure] = []
        var sampleKeys = Set<String>()
        var writtenSamples: [String] = []
        var coverage = ScenarioCoverageAccumulator()

        var matrixRowsVerified = 0
        var deepRowsVerified = 0

        func verify(row: WorkbenchScenarioRow, fixture: WorkbenchScenarioFixture, registration: BossWorkbenchMCPRegistrationSnapshot) throws {
            let recoveryAction = recoveryPlanner.planRecovery(for: fixture.entry, latestRun: fixture.latestRun).action
            let summary = summarizer.summarize(fixture.state)
            let readiness = readinessBuilder.build(
                state: fixture.state,
                summary: summary,
                mcpRegistration: registration,
                executableHealth: fixture.executableHealth,
                bossWatchIsEnabled: fixture.bossWatchEnabled
            )
            let commandPlan = try commandPlanner.recoveryPlan(
                for: fixture.entry,
                latestRun: fixture.latestRun,
                action: recoveryAction
            )

            let scenario = NativeScenario(
                row: row,
                fixture: fixture,
                summary: summary,
                recoveryAction: recoveryAction,
                readinessState: readiness.state.rawValue,
                commandLine: commandPlan.displayCommand
            )
            coverage.record(
                row: row,
                fixture: fixture,
                registration: registration,
                recoveryAction: recoveryAction,
                readinessState: readiness.state.rawValue
            )

            for viewport in viewports {
                let sampleKey = "\(row.surface)-\(row.terminal)-\(viewport.name)"
                let shouldWriteSample = writeSamples
                    && writtenSamples.count < sampleLimit
                    && !sampleKeys.contains(sampleKey)
                let render = autoreleasepool {
                    NativeScenarioRenderer(scenario: scenario, viewport: viewport).render(encodePNG: shouldWriteSample)
                }
                renderPasses += 1
                failures.append(contentsOf: render.failures)

                if writeSamples,
                   shouldWriteSample,
                   let data = render.pngData {
                    sampleKeys.insert(sampleKey)
                    let fileName = "\(row.caseID)-\(viewport.name)-\(row.surface)-\(row.terminal).png"
                    let url = sampleDirectory.appendingPathComponent(fileName)
                    try data.write(to: url)
                    writtenSamples.append(url.path)
                }
            }
        }

        for row in matrix.rows.prefix(maxRows ?? matrix.rows.count) {
            let fixture = try matrix.fixture(for: row)
            try verify(row: row, fixture: fixture, registration: matrix.registration(for: row))
            rowsVerified += 1
            matrixRowsVerified += 1
        }

        if deepScenarioCount > 0 {
            var generator = DeepScenarioGenerator(seed: deepSeed, matrix: matrix)
            for index in 0..<deepScenarioCount {
                let generated = try generator.scenario(at: index)
                try verify(row: generated.row, fixture: generated.fixture, registration: generated.registration)
                rowsVerified += 1
                deepRowsVerified += 1
            }
        }

        return ScenarioVerifierSummary(
            rowsVerified: rowsVerified,
            matrixRowsVerified: matrixRowsVerified,
            deepRowsVerified: deepRowsVerified,
            deepSeed: deepRowsVerified > 0 ? deepSeed : nil,
            renderPasses: renderPasses,
            viewportNames: viewports.map(\.name),
            coverage: coverage.summary(viewports: viewports, renderPasses: renderPasses),
            sampleFiles: writtenSamples,
            failures: failures
        )
    }
}

struct NativeScenario {
    var row: WorkbenchScenarioRow
    var fixture: WorkbenchScenarioFixture
    var summary: WorkspaceSummary
    var recoveryAction: RecoveryAction
    var readinessState: String
    var commandLine: String
}

struct DeepGeneratedScenario {
    var row: WorkbenchScenarioRow
    var fixture: WorkbenchScenarioFixture
    var registration: BossWorkbenchMCPRegistrationSnapshot
}

struct DeepScenarioGenerator {
    private var random: SeededRandom
    private let matrix: WorkbenchScenarioMatrix

    private let terminals = ["claude", "codex", "copilot", "generic_tui", "local_shell"]
    private let lifecycles = ["configured", "running", "waiting_for_input", "needs_recovery", "manual_action_needed"]
    private let trustPostures = ["trusted_auto_session", "trusted_auto_no_session", "trusted_no_auto", "untrusted_auto", "untrusted_no_auto"]
    private let surfaces = ["sidebar_dashboard", "sidebar_hidden_dashboard", "boss_pane_collapsed", "terminal_focus", "archived_session"]
    private let bossBridgeStates = ["registered", "not_registered", "needs_update", "agent_missing"]
    private let executableHealthStates = ["available", "missing"]
    private let bossNames = ["slugger", "serpent-guide", "operator-boss", "night-watch", "release-captain"]
    private let projectNames = [
        "Workbench",
        "Harness P0 Recovery",
        "Ouro Mailroom",
        "Native App Polish",
        "Very Long Project Scope Name For Compact Sidebar Stress"
    ]
    private let sessionNames = [
        "Claude",
        "Codex",
        "Copilot",
        "Generic TUI",
        "Local Shell",
        "Release Notes",
        "Restart Drill",
        "This Terminal Has A Long Human Name That Must Truncate"
    ]
    private let commandFragments = [
        "audit-ui --window compact",
        "resume --last",
        "test --filter recovery",
        "ship --dry-run",
        "watch --boss",
        "plan \"quoted scope with spaces\""
    ]

    init(seed: UInt64, matrix: WorkbenchScenarioMatrix) {
        self.random = SeededRandom(seed: seed)
        self.matrix = matrix
    }

    mutating func scenario(at index: Int) throws -> DeepGeneratedScenario {
        var row = matrix.rows[Int(random.next() % UInt64(matrix.rows.count))]
        row.caseID = "WB-DEEP-\(String(format: "%05d", index + 1))"
        row.terminal = pick(terminals)
        row.lifecycle = pick(lifecycles)
        row.trustResumeMetadata = pick(trustPostures)
        row.surface = pick(surfaces)
        row.bossBridge = pick(bossBridgeStates)
        row.executableHealth = pick(executableHealthStates)

        var fixture = try matrix.fixture(for: row)
        let bossName = pick(bossNames)
        fixture.state.boss = BossAgentSelection(agentName: bossName, scope: pick(["machine", "project"]))
        fixture.state.updatedAt = Date(timeIntervalSince1970: 1_779_724_800 + TimeInterval(index))

        mutateSelectedEntry(in: &fixture, index: index)
        addGeneratedProjectsAndPeers(to: &fixture, index: index)
        rebuildExecutableHealth(for: &fixture, selectedHealth: row.executableHealth)

        var registration = matrix.registration(for: row)
        registration.agentName = bossName
        registration.agentConfigPath = "/Users/ari/AgentBundles/\(bossName).ouro/agent.json"
        registration.detail = registration.status.rawValue

        return DeepGeneratedScenario(row: row, fixture: fixture, registration: registration)
    }

    private mutating func mutateSelectedEntry(in fixture: inout WorkbenchScenarioFixture, index: Int) {
        fixture.entry.name = pick(sessionNames)
        fixture.entry.workingDirectory = generatedWorkingDirectory(index: index)
        fixture.entry.lastSummary = pick([
            "Actively editing Workbench internals.",
            "Waiting on terminal output.",
            "Preparing restart-safe resume metadata.",
            "Checking boss bridge registration.",
            "Reviewing compact-window layout."
        ])
        fixture.entry.notes = pick([
            nil,
            "Deep verifier generated note.",
            "Stress: long notes should stay out of compact chrome.",
            "Boss can keep this moving when trust and recovery are clear."
        ])
        if random.nextBool() {
            fixture.entry.arguments += [pick(commandFragments)]
        }
        if fixture.entry.kind == .terminalAgent, fixture.entry.agentKind == nil {
            fixture.entry.agentKind = .custom
        }

        replace(entry: fixture.entry, in: &fixture.state)

        if var run = fixture.latestRun {
            run.pid = run.status == .running ? Int32(10_000 + index % 30_000) : nil
            run.terminalSessionId = fixture.entry.autoResume && random.nextBool()
                ? "deep-session-\(index)-\(String(format: "%08llx", random.next()))"
                : run.terminalSessionId
            run.transcriptPath = "\(fixture.entry.workingDirectory)/.ouro-workbench/transcripts/\(fixture.entry.name)-\(index).log"
            run.lastOutputAt = Date(timeIntervalSince1970: 1_779_724_800 + TimeInterval(index))
            fixture.latestRun = run
            replace(run: run, in: &fixture.state)
        }
    }

    private mutating func addGeneratedProjectsAndPeers(to fixture: inout WorkbenchScenarioFixture, index: Int) {
        let projectCount = 1 + Int(random.next() % 4)
        fixture.state.projects = (0..<projectCount).map { slot in
            WorkbenchProject(
                id: stableUUID(index: index, slot: slot, namespace: 0xA1),
                name: pick(projectNames),
                rootPath: "/tmp/ouro-workbench/deep/\(index)/project-\(slot)",
                boss: fixture.state.boss
            )
        }
        let selectedProject = fixture.state.projects[Int(random.next() % UInt64(fixture.state.projects.count))]
        fixture.entry.projectId = selectedProject.id
        fixture.state.selectedProjectId = selectedProject.id
        replace(entry: fixture.entry, in: &fixture.state)

        let peerCount = Int(random.next() % 6)
        for slot in 0..<peerCount {
            let terminal = pick(terminals)
            let status = processStatus(for: pick(lifecycles))
            let project = fixture.state.projects[Int(random.next() % UInt64(fixture.state.projects.count))]
            let peer = processEntry(
                terminal: terminal,
                id: stableUUID(index: index, slot: slot, namespace: 0xB2),
                projectId: project.id,
                name: "\(pick(sessionNames)) \(slot + 1)",
                workingDirectory: "/tmp/ouro-workbench/deep/\(index)/peer-\(slot)"
            )
            fixture.state.processEntries.append(peer)

            if status != .configured {
                fixture.state.processRuns.append(ProcessRun(
                    id: stableUUID(index: index, slot: slot, namespace: 0xC3),
                    entryId: peer.id,
                    pid: status == .running ? Int32(20_000 + slot) : nil,
                    status: status,
                    startedAt: Date(timeIntervalSince1970: 1_779_724_000 + TimeInterval(index + slot)),
                    terminalSessionId: peer.autoResume && random.nextBool() ? "peer-session-\(index)-\(slot)" : nil,
                    transcriptPath: "\(peer.workingDirectory)/transcript.log"
                ))
            }
        }

        fixture.state.selectedEntryId = fixture.entry.id
    }

    private mutating func rebuildExecutableHealth(for fixture: inout WorkbenchScenarioFixture, selectedHealth: String) {
        var health: [UUID: ExecutableHealth] = [:]
        for entry in fixture.state.processEntries where !entry.isArchived {
            let available = entry.id == fixture.entry.id
                ? selectedHealth == "available"
                : random.next() % 5 != 0
            health[entry.id] = ExecutableHealth(
                executable: ExecutableHealthTarget.executable(for: entry),
                resolvedPath: available ? "/usr/bin/\(entry.executable)" : nil,
                status: available ? .available : .missing,
                detail: available ? "Found command." : "Command missing in generated deep scenario."
            )
        }
        fixture.executableHealth = health
    }

    private mutating func processEntry(
        terminal: String,
        id: UUID,
        projectId: UUID,
        name: String,
        workingDirectory: String
    ) -> ProcessEntry {
        let posture = pick(trustPostures)
        let trust = posture.hasPrefix("trusted") ? ProcessTrust.trusted : .untrusted
        let autoResume = !posture.contains("no_auto")
        switch terminal {
        case "claude":
            return ProcessEntry(id: id, projectId: projectId, name: name, kind: .terminalAgent, agentKind: .claudeCode, executable: "claude", arguments: ["--dangerously-skip-permissions"], workingDirectory: workingDirectory, trust: trust, autoResume: autoResume)
        case "codex":
            return ProcessEntry(id: id, projectId: projectId, name: name, kind: .terminalAgent, agentKind: .openAICodex, executable: "codex", arguments: ["--yolo"], workingDirectory: workingDirectory, trust: trust, autoResume: autoResume)
        case "copilot":
            return ProcessEntry(id: id, projectId: projectId, name: name, kind: .terminalAgent, agentKind: .githubCopilotCLI, executable: "gh", arguments: ["copilot", "--", "--yolo"], workingDirectory: workingDirectory, trust: trust, autoResume: autoResume)
        case "generic_tui":
            return ProcessEntry(id: id, projectId: projectId, name: name, kind: .terminalAgent, agentKind: .custom, executable: "/bin/zsh", arguments: ["-lc", "aider --yes && \(pick(commandFragments))"], workingDirectory: workingDirectory, trust: trust, autoResume: autoResume)
        default:
            return ProcessEntry(id: id, projectId: projectId, name: name, kind: .shell, executable: "/bin/zsh", arguments: ["-l"], workingDirectory: workingDirectory, trust: trust, autoResume: autoResume)
        }
    }

    private func replace(entry: ProcessEntry, in state: inout WorkspaceState) {
        guard let index = state.processEntries.firstIndex(where: { $0.id == entry.id }) else {
            state.processEntries.append(entry)
            return
        }
        state.processEntries[index] = entry
    }

    private func replace(run: ProcessRun, in state: inout WorkspaceState) {
        guard let index = state.processRuns.firstIndex(where: { $0.id == run.id }) else {
            state.processRuns.append(run)
            return
        }
        state.processRuns[index] = run
    }

    private mutating func pick<T>(_ values: [T]) -> T {
        values[Int(random.next() % UInt64(values.count))]
    }

    private func processStatus(for lifecycle: String) -> ProcessStatus {
        switch lifecycle {
        case "running":
            return .running
        case "waiting_for_input":
            return .waitingForInput
        case "needs_recovery":
            return .needsRecovery
        case "manual_action_needed":
            return .manualActionNeeded
        default:
            return .configured
        }
    }

    private func generatedWorkingDirectory(index: Int) -> String {
        "/tmp/ouro-workbench/deep/\(index)/\(projectNames[index % projectNames.count].replacingOccurrences(of: " ", with: "-"))"
    }

    private func stableUUID(index: Int, slot: Int, namespace: UInt64) -> UUID {
        let value = (UInt64(index + 1) << 12) ^ (UInt64(slot + 1) << 4) ^ namespace
        let prefix = 0xD000_0000 | ((namespace & 0xFF) << 16) | UInt64(slot & 0xFFFF)
        return UUID(uuidString: String(format: "%08llX-0000-0000-0000-%012llX", prefix, value & 0xFFFF_FFFF_FFFF))!
    }
}

struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xC0DE_CAFE_F00D_BAAD : seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func nextBool() -> Bool {
        next() & 1 == 0
    }
}

struct ScenarioCoverageAccumulator {
    private var digest = FNV1a64()
    private var coverage = ScenarioCoverageSummary(
        digest: "",
        rowCount: 0,
        renderPasses: 0,
        terminals: [:],
        lifecycles: [:],
        trustResumePostures: [:],
        surfaces: [:],
        bossBridgeStates: [:],
        executableHealthStates: [:],
        recoveryActions: [:],
        readinessStates: [:],
        bossAgents: [:],
        projectCounts: [:],
        processCounts: [:],
        runCounts: [:],
        viewports: [:]
    )

    mutating func record(
        row: WorkbenchScenarioRow,
        fixture: WorkbenchScenarioFixture,
        registration: BossWorkbenchMCPRegistrationSnapshot,
        recoveryAction: RecoveryAction,
        readinessState: String
    ) {
        coverage.rowCount += 1
        increment(\.terminals, row.terminal)
        increment(\.lifecycles, row.lifecycle)
        increment(\.trustResumePostures, row.trustResumeMetadata)
        increment(\.surfaces, row.surface)
        increment(\.bossBridgeStates, registration.status.rawValue)
        increment(\.executableHealthStates, row.executableHealth)
        increment(\.recoveryActions, recoveryAction.rawValue)
        increment(\.readinessStates, readinessState)
        increment(\.bossAgents, fixture.state.boss.agentName)
        increment(\.projectCounts, String(fixture.state.projects.count))
        increment(\.processCounts, String(fixture.state.processEntries.count))
        increment(\.runCounts, String(fixture.state.processRuns.count))

        digest.update(row.caseID)
        digest.update(row.terminal)
        digest.update(row.lifecycle)
        digest.update(row.trustResumeMetadata)
        digest.update(row.surface)
        digest.update(registration.status.rawValue)
        digest.update(row.executableHealth)
        digest.update(recoveryAction.rawValue)
        digest.update(readinessState)
        digest.update(fixture.state.boss.agentName)
        digest.update(String(fixture.state.projects.count))
        digest.update(String(fixture.state.processEntries.count))
        digest.update(String(fixture.state.processRuns.count))
        digest.update(fixture.entry.name)
        digest.update(fixture.entry.executable)
        digest.update(fixture.entry.arguments.joined(separator: "\u{1f}"))
        digest.update(fixture.entry.workingDirectory)
        digest.update(fixture.latestRun?.terminalSessionId ?? "")
    }

    func summary(viewports: [ScenarioViewport], renderPasses: Int) -> ScenarioCoverageSummary {
        var next = coverage
        next.renderPasses = renderPasses
        next.viewports = Dictionary(uniqueKeysWithValues: viewports.map { viewport in
            (viewport.name, coverage.rowCount)
        })
        var finalDigest = digest
        for viewport in viewports {
            finalDigest.update(viewport.name)
            finalDigest.update(String(Int(viewport.width)))
            finalDigest.update(String(Int(viewport.height)))
        }
        finalDigest.update(String(renderPasses))
        next.digest = finalDigest.hexDigest
        return next
    }

    private mutating func increment(
        _ keyPath: WritableKeyPath<ScenarioCoverageSummary, [String: Int]>,
        _ key: String
    ) {
        coverage[keyPath: keyPath][key, default: 0] += 1
    }
}

struct ScenarioCoverageSummary: Codable {
    var digest: String
    var rowCount: Int
    var renderPasses: Int
    var terminals: [String: Int]
    var lifecycles: [String: Int]
    var trustResumePostures: [String: Int]
    var surfaces: [String: Int]
    var bossBridgeStates: [String: Int]
    var executableHealthStates: [String: Int]
    var recoveryActions: [String: Int]
    var readinessStates: [String: Int]
    var bossAgents: [String: Int]
    var projectCounts: [String: Int]
    var processCounts: [String: Int]
    var runCounts: [String: Int]
    var viewports: [String: Int]
}

struct FNV1a64 {
    private var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func update(_ string: String) {
        for byte in string.utf8 {
            value ^= UInt64(byte)
            value &*= 0x0000_0100_0000_01b3
        }
        value ^= UInt64(0xff)
        value &*= 0x0000_0100_0000_01b3
    }

    var hexDigest: String {
        String(format: "%016llx", value)
    }
}

struct ScenarioViewport {
    var name: String
    var width: CGFloat
    var height: CGFloat

    var size: CGSize {
        CGSize(width: width, height: height)
    }
}

struct NativeScenarioRenderer {
    var scenario: NativeScenario
    var viewport: ScenarioViewport

    func render(encodePNG: Bool) -> NativeScenarioRender {
        var canvas = ScenarioCanvas(size: viewport.size, drawRaster: encodePNG)
        let surface = WorkbenchMatrixSurface(rawValue: scenario.row.surface) ?? .sidebarDashboard
        let chrome = WorkbenchSurfaceChrome.contract(for: surface)
        canvas.fill(canvas.bounds, color: .white)

        switch surface {
        case .terminalFocus:
            drawTerminalFocus(canvas: &canvas, chrome: chrome)
        case .sidebarDashboard:
            drawWorkbench(canvas: &canvas, sidebarVisible: true, bossPaneVisible: true, archived: false)
        case .sidebarHiddenDashboard:
            drawWorkbench(canvas: &canvas, sidebarVisible: false, bossPaneVisible: true, archived: false)
        case .bossPaneCollapsed:
            drawWorkbench(canvas: &canvas, sidebarVisible: true, bossPaneVisible: false, archived: false)
        case .archivedSession:
            drawWorkbench(canvas: &canvas, sidebarVisible: true, bossPaneVisible: true, archived: true)
        }
        canvas.drawWindowChrome()

        let pngData = encodePNG ? canvas.pngData() : nil
        return NativeScenarioRender(
            caseID: scenario.row.caseID,
            viewport: viewport.name,
            pngData: pngData,
            failures: verify(canvas: canvas, surface: surface, chrome: chrome)
        )
    }

    private func drawTerminalFocus(canvas: inout ScenarioCanvas, chrome: WorkbenchSurfaceChromeContract) {
        canvas.fill(canvas.bounds, color: .black)
        let controlY = CGFloat(chrome.floatingControlsTopInset)
        let controls = CGRect(x: canvas.size.width - 360, y: controlY, width: 340, height: 40)
        canvas.fill(controls, color: NSColor.white.withAlphaComponent(0.25), radius: 8)
        canvas.text(scenario.fixture.entry.name, in: controls.insetBy(dx: 12, dy: 12), role: .terminalControl)
        canvas.text("Exit Full Screen   Ctrl-C   Esc   Stop", in: controls.insetBy(dx: 100, dy: 12), role: .terminalControl)

        let terminalTop = CGFloat(chrome.terminalContentTopInset)
        let content = CGRect(x: 0, y: terminalTop, width: canvas.size.width, height: canvas.size.height - terminalTop)
        canvas.fill(content, color: .black)
        drawTerminalLines(canvas: &canvas, in: content.insetBy(dx: 0, dy: 18), role: .terminalText)
    }

    private func drawWorkbench(
        canvas: inout ScenarioCanvas,
        sidebarVisible: Bool,
        bossPaneVisible: Bool,
        archived: Bool
    ) {
        let sidebarWidth: CGFloat = sidebarVisible ? min(230, canvas.size.width * 0.28) : 0
        if sidebarVisible {
            let sidebar = CGRect(x: 0, y: 0, width: sidebarWidth, height: canvas.size.height)
            canvas.fill(sidebar, color: NSColor(calibratedWhite: 0.965, alpha: 1))
            canvas.text("Groups", in: CGRect(x: 16, y: 92, width: sidebarWidth - 32, height: 18), role: .sidebarText)
            canvas.text(selectedProjectName, in: CGRect(x: 16, y: 120, width: sidebarWidth - 32, height: 18), role: .sidebarText)
            canvas.text(archived ? "Archived" : scenario.fixture.entry.name, in: CGRect(x: 16, y: 158, width: sidebarWidth - 32, height: 18), role: .sidebarText)
        }

        let detailX = sidebarWidth
        let detailWidth = canvas.size.width - detailX
        let header = CGRect(x: detailX, y: 0, width: detailWidth, height: 92)
        canvas.fill(header, color: .white)
        canvas.text("Boss: \(scenario.fixture.state.boss.agentName)", in: CGRect(x: detailX + 16, y: 54, width: 180, height: 18), role: .headerText)
        canvas.text(scenario.summary.oneLineStatus, in: CGRect(x: detailX + 16, y: 74, width: 190, height: 14), role: .headerText)
        let headerControls = trailingRect(in: header, preferredWidth: 400, y: 60, height: 18, minimumX: detailX + 220)
        canvas.text("TTFA   Commands   Watch   Refresh   Check In", in: headerControls, role: .headerText)
        canvas.divider(y: header.maxY, role: .headerDivider)

        var currentY = header.maxY
        if bossPaneVisible {
            let bossHeight = min(canvas.size.height * 0.43, max(185, canvas.size.height - header.height - 210))
            let boss = CGRect(x: detailX, y: currentY, width: detailWidth, height: bossHeight)
            drawBossDashboard(canvas: &canvas, in: boss)
            currentY = boss.maxY
            canvas.divider(y: currentY, role: .terminalSplit)
        }

        let preferredTerminalHeaderHeight: CGFloat = archived ? 150 : 88
        let terminalHeaderHeight = min(preferredTerminalHeaderHeight, max(0, canvas.size.height - currentY))
        let terminalHeader = CGRect(x: detailX, y: currentY, width: detailWidth, height: terminalHeaderHeight)
        canvas.fill(terminalHeader, color: .white)
        if archived {
            drawVisibleLine("Archived: \(scenario.fixture.entry.name)", y: currentY + 18, in: terminalHeader, canvas: &canvas, role: .archivedText)
            drawVisibleLine("History preserved; no active terminal is launched.", y: currentY + 42, in: terminalHeader, canvas: &canvas, role: .archivedText)
            drawVisibleLine(scenario.commandLine, y: currentY + 68, in: terminalHeader, canvas: &canvas, role: .archivedText)
            return
        }

        canvas.text(scenario.fixture.entry.name, in: CGRect(x: detailX + 16, y: currentY + 16, width: 220, height: 22), role: .terminalHeaderText)
        canvas.text(scenario.commandLine, in: CGRect(x: detailX + 16, y: currentY + 42, width: detailWidth * 0.55, height: 16), role: .terminalHeaderText)
        let terminalControls = trailingRect(in: terminalHeader, preferredWidth: 480, y: currentY + 28, height: 18, minimumX: detailX + 250)
        canvas.text("Ask Boss   Full Screen   Ctrl-C   Esc   Stop   Restart", in: terminalControls, role: .terminalControl)
        currentY = terminalHeader.maxY

        let terminal = CGRect(x: detailX, y: currentY, width: detailWidth, height: canvas.size.height - currentY)
        canvas.fill(terminal, color: .black)
        drawTerminalLines(canvas: &canvas, in: terminal.insetBy(dx: 0, dy: 18), role: .terminalText)
    }

    private func drawBossDashboard(canvas: inout ScenarioCanvas, in rect: CGRect) {
        canvas.fill(rect, color: .white)
        var y = rect.minY + 16

        func drawDashboardLine(_ text: String, height: CGFloat = 18, advance: CGFloat = 26) {
            guard y + height <= rect.maxY - 8 else {
                return
            }
            canvas.text(text, in: CGRect(x: rect.minX + 16, y: y, width: rect.width - 32, height: height), role: .bossDashboardText)
            y += advance
        }

        drawDashboardLine("Boss Watch \(scenario.fixture.bossWatchEnabled ? "watching" : "paused")", height: 16, advance: 24)
        let runningCount = scenario.summary.processSnapshots.filter { $0.status == .running }.count
        let waitingCount = scenario.summary.waitingOnHuman.count
        let recoveryCount = scenario.summary.needsRecovery.count
        drawDashboardLine("running \(runningCount)   waiting \(waitingCount)   recovery \(recoveryCount)   production mode", advance: 30)
        drawDashboardLine("Boss Line    Ask \(scenario.fixture.state.boss.agentName) about the Workbench")
        drawDashboardLine("What's Going On?   Waiting On Me?   Keep Moving   Respond For Me", advance: 32)
        drawDashboardLine("Ouro Agents   \(scenario.fixture.state.projects.count) groups, \(scenario.fixture.state.processEntries.count) terminals; boss \(scenario.fixture.state.boss.agentName)")
        drawDashboardLine("\(scenario.readinessState) · selected \(scenario.fixture.entry.name)", advance: 28)
        if scenario.row.executableHealth == "missing" || scenario.row.bossBridge != "registered" {
            drawDashboardLine("Mailbox warnings: \(scenario.row.bossBridge); executable \(scenario.row.executableHealth)", advance: 28)
        }
        drawDashboardLine("Transcript Search      Native Runtime      Recovery Drill      Workbench MCP", advance: 28)
        drawDashboardLine("Action Log 12 recent   latest action is auditable")
    }

    private func drawVisibleLine(
        _ text: String,
        y: CGFloat,
        in container: CGRect,
        canvas: inout ScenarioCanvas,
        role: ScenarioRegionRole
    ) {
        let height: CGFloat = 18
        guard y + height <= container.maxY else {
            return
        }
        canvas.text(
            text,
            in: CGRect(x: container.minX + 16, y: y, width: max(1, container.width - 32), height: height),
            role: role
        )
    }

    private var selectedProjectName: String {
        guard let selectedProjectId = scenario.fixture.state.selectedProjectId,
              let project = scenario.fixture.state.projects.first(where: { $0.id == selectedProjectId }) else {
            return "Matrix"
        }
        return project.name
    }

    private func drawTerminalLines(canvas: inout ScenarioCanvas, in rect: CGRect, role: ScenarioRegionRole) {
        guard rect.height >= 18 else {
            return
        }
        let prompt = "ouro@ouroboros-host  ~"
        let stateLine = "\(scenario.row.terminal) \(scenario.row.lifecycle) \(scenario.readinessState)"
        let promptRect = CGRect(x: rect.minX, y: rect.minY, width: max(1, rect.width - 8), height: 18)
        canvas.text(prompt, in: promptRect, role: role, color: .systemTeal, font: .monospacedSystemFont(ofSize: 13, weight: .bold))
        guard rect.height >= 42 else {
            return
        }
        let secondLineY = min(rect.minY + 24, rect.maxY - 18)
        canvas.text("> \(stateLine)", in: CGRect(x: rect.minX, y: secondLineY, width: max(1, rect.width - 8), height: 18), role: role, color: .white, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        canvas.text(scenario.recoveryAction.rawValue, in: CGRect(x: max(rect.minX, rect.maxX - 220), y: secondLineY, width: min(210, rect.width), height: 18), role: role, color: .lightGray, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
    }

    private func verify(
        canvas: ScenarioCanvas,
        surface: WorkbenchMatrixSurface,
        chrome: WorkbenchSurfaceChromeContract
    ) -> [ScenarioVerifierFailure] {
        var failures: [ScenarioVerifierFailure] = []
        func fail(_ message: String) {
            failures.append(ScenarioVerifierFailure(caseID: scenario.row.caseID, viewport: viewport.name, message: message))
        }

        for region in canvas.regions where region.role.isVisibleTextOrControl {
            if !canvas.bounds.contains(region.rect) {
                fail("\(region.name) escapes viewport: \(region.rect)")
            }
        }

        let trafficLights = canvas.regions.filter { $0.role == .trafficLight }
        if surface == .terminalFocus {
            if chrome.terminalContentTopInset < WorkbenchSurfaceChrome.trafficLightSafeTopInset {
                fail("terminal focus content inset does not reserve traffic-light region")
            }
            if chrome.floatingControlsTopInset < WorkbenchSurfaceChrome.trafficLightSafeTopInset {
                fail("terminal focus controls inset does not reserve traffic-light region")
            }
            for region in canvas.regions where region.role == .terminalText || region.role == .terminalControl {
                if trafficLights.contains(where: { $0.rect.intersects(region.rect) }) {
                    fail("\(region.name) overlaps native traffic-light chrome")
                }
            }
        }

        if surface == .bossPaneCollapsed {
            let dashboardText = canvas.regions.filter { $0.role == .bossDashboardText }
            if !dashboardText.isEmpty {
                fail("boss dashboard content is visible while boss pane is collapsed")
            }
        }

        if surface != .terminalFocus && surface != .bossPaneCollapsed {
            guard let split = canvas.regions.first(where: { $0.role == .terminalSplit }) else {
                fail("expanded workbench surface has no terminal split boundary")
                return failures
            }
            for region in canvas.regions where region.role == .bossDashboardText {
                if region.rect.maxY > split.rect.minY - 2 {
                    fail("\(region.name) is clipped by terminal split boundary")
                }
            }
        }

        if surface == .archivedSession {
            let activeTerminalText = canvas.regions.filter { $0.role == .terminalText }
            if !activeTerminalText.isEmpty {
                fail("archived session rendered active terminal text")
            }
        }

        return failures
    }

    private func trailingRect(
        in container: CGRect,
        preferredWidth: CGFloat,
        y: CGFloat,
        height: CGFloat,
        minimumX: CGFloat
    ) -> CGRect {
        let horizontalPadding: CGFloat = 16
        let maxWidth = max(1, container.maxX - minimumX - horizontalPadding)
        let width = min(preferredWidth, maxWidth)
        let x = max(minimumX, container.maxX - width - horizontalPadding)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

struct NativeScenarioRender {
    var caseID: String
    var viewport: String
    var pngData: Data?
    var failures: [ScenarioVerifierFailure]
}

struct ScenarioCanvas {
    var size: CGSize
    var image: NSBitmapImageRep?
    var regions: [ScenarioRegion] = []

    init(size: CGSize, drawRaster: Bool) {
        self.size = size
        self.image = drawRaster
            ? NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width),
                pixelsHigh: Int(size.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
            : nil
    }

    var bounds: CGRect {
        CGRect(origin: .zero, size: size)
    }

    mutating func drawWindowChrome() {
        for (index, color) in [NSColor.systemRed, NSColor.systemYellow, NSColor.systemGreen].enumerated() {
            let rect = CGRect(x: 18 + CGFloat(index * 22), y: 18, width: 14, height: 14)
            fill(rect, color: color, radius: 7, role: .trafficLight, name: "traffic-light-\(index)")
        }
    }

    mutating func divider(y: CGFloat, role: ScenarioRegionRole) {
        let rect = CGRect(x: 0, y: y, width: size.width, height: 1)
        fill(rect, color: NSColor(calibratedWhite: 0.86, alpha: 1), role: role, name: role.rawValue)
    }

    mutating func fill(
        _ rect: CGRect,
        color: NSColor,
        radius: CGFloat = 0,
        role: ScenarioRegionRole = .background,
        name: String? = nil
    ) {
        draw { context in
            context.setFillColor(color.cgColor)
            let converted = convert(rect)
            if radius > 0 {
                context.addPath(CGPath(roundedRect: converted, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            } else {
                context.fill(converted)
            }
        }
        if role != .background {
            regions.append(ScenarioRegion(name: name ?? role.rawValue, role: role, rect: rect))
        }
    }

    mutating func text(
        _ string: String,
        in rect: CGRect,
        role: ScenarioRegionRole,
        color: NSColor = .black,
        font: NSFont = .systemFont(ofSize: 12)
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        guard rect.width.isFinite,
              rect.height.isFinite,
              rect.width > 0,
              rect.height > 0 else {
            regions.append(ScenarioRegion(name: string, role: role, rect: rect))
            return
        }
        draw { _ in
            NSAttributedString(string: string, attributes: attributes).draw(in: convert(rect))
        }
        regions.append(ScenarioRegion(name: string, role: role, rect: rect))
    }

    func pngData() -> Data? {
        image?.representation(using: .png, properties: [:])
    }

    private func convert(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func draw(_ block: (CGContext) -> Void) {
        guard let image,
              let context = NSGraphicsContext(bitmapImageRep: image) else {
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        block(context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
    }
}

struct ScenarioRegion {
    var name: String
    var role: ScenarioRegionRole
    var rect: CGRect
}

enum ScenarioRegionRole: String {
    case background
    case trafficLight
    case headerText
    case sidebarText
    case bossDashboardText
    case terminalHeaderText
    case terminalText
    case terminalControl
    case headerDivider
    case terminalSplit
    case archivedText

    var isVisibleTextOrControl: Bool {
        switch self {
        case .background, .terminalSplit, .trafficLight, .headerDivider:
            return false
        case .headerText, .sidebarText, .bossDashboardText, .terminalHeaderText, .terminalText, .terminalControl, .archivedText:
            return true
        }
    }
}

struct ScenarioVerifierSummary: Codable {
    var rowsVerified: Int
    var matrixRowsVerified: Int
    var deepRowsVerified: Int
    var deepSeed: UInt64?
    var renderPasses: Int
    var viewportNames: [String]
    var coverage: ScenarioCoverageSummary
    var sampleFiles: [String]
    var failures: [ScenarioVerifierFailure]

    var consoleSummary: String {
        [
            "Workbench native scenario verifier:",
            "rows verified: \(rowsVerified)",
            "matrix rows: \(matrixRowsVerified)",
            "deep generated rows: \(deepRowsVerified)",
            deepSeed.map { "deep seed: \($0)" },
            "render passes: \(renderPasses)",
            "viewports: \(viewportNames.joined(separator: ", "))",
            "coverage digest: \(coverage.digest)",
            "sample files: \(sampleFiles.count)",
            "failures: \(failures.count)"
        ].compactMap { $0 }.joined(separator: "\n")
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url)
    }
}

struct ScenarioVerifierFailure: Codable {
    var caseID: String
    var viewport: String
    var message: String
}

enum ScenarioVerifierError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case missingValue(String)

    var description: String {
        switch self {
        case let .invalidArgument(argument):
            return "invalid argument: \(argument)"
        case let .missingValue(argument):
            return "missing value after \(argument)"
        }
    }
}
