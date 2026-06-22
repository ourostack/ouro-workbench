import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchScenarioMatrixTests: XCTestCase {
    func testMatrixLoadRejectsEmptyFileInvalidHeaderAndWrongColumnCount() throws {
        let emptyURL = try writeMatrix("empty", "")
        XCTAssertThrowsError(try WorkbenchScenarioMatrix.load(from: emptyURL)) { error in
            XCTAssertEqual(error as? WorkbenchScenarioMatrixError, .emptyMatrix)
            XCTAssertEqual(String(describing: error), "scenario matrix is empty")
        }

        let badHeaderURL = try writeMatrix("bad-header", "case_id\tterminal\n")
        XCTAssertThrowsError(try WorkbenchScenarioMatrix.load(from: badHeaderURL)) { error in
            XCTAssertEqual(error as? WorkbenchScenarioMatrixError, .invalidHeader(["case_id", "terminal"]))
            XCTAssertEqual(String(describing: error), "invalid matrix header: case_id,terminal")
        }

        let shortRowURL = try writeMatrix("short-row", WorkbenchScenarioMatrix.expectedHeader.joined(separator: "\t") + "\nWB-1\tclaude\n")
        XCTAssertThrowsError(try WorkbenchScenarioMatrix.load(from: shortRowURL)) { error in
            XCTAssertEqual(error as? WorkbenchScenarioMatrixError, .invalidColumnCount(line: 2, count: 2))
            XCTAssertEqual(String(describing: error), "line 2 has 2 columns")
        }
    }

    func testMatrixFixtureRejectsInvalidTerminalLifecycleTrustAndSurfaceValues() throws {
        var row = validRow()
        row.terminal = "mystery"
        XCTAssertThrowsError(try WorkbenchScenarioMatrix(rows: []).fixture(for: row)) { error in
            XCTAssertEqual(error as? WorkbenchScenarioMatrixError, .invalidValue("terminal mystery"))
        }

        row = validRow()
        row.lifecycle = "paused"
        XCTAssertThrowsError(try WorkbenchScenarioMatrix(rows: []).fixture(for: row)) { error in
            XCTAssertEqual(error as? WorkbenchScenarioMatrixError, .invalidValue("lifecycle paused"))
        }

        XCTAssertThrowsError(try WorkbenchTrustResumePosture(rawValue: "unknown")) { error in
            XCTAssertEqual(error as? WorkbenchScenarioMatrixError, .invalidValue("trust_resume_metadata unknown"))
        }
        XCTAssertThrowsError(try WorkbenchSurfacePosture(rawValue: "unknown")) { error in
            XCTAssertEqual(error as? WorkbenchScenarioMatrixError, .invalidValue("surface unknown"))
            XCTAssertEqual(String(describing: error), "invalid matrix value: surface unknown")
        }
    }

    func testRegistrationDefaultsUnknownBridgeToInvalidConfig() throws {
        var row = validRow()
        row.bossBridge = "future_status"

        let registration = WorkbenchScenarioMatrix(rows: []).registration(for: row)

        XCTAssertEqual(registration.status, .invalidConfig)
        XCTAssertEqual(registration.detail, "invalidConfig")
    }

    func testScenarioMatrixContainsExactlyFiveThousandCasesWithOptimalOutcomes() throws {
        let rows = try loadMatrix().rows

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
        let matrix = try loadMatrix()
        let rows = matrix.rows
        let summarizer = WorkspaceSummarizer()
        let readinessBuilder = AutonomyReadinessBuilder()
        let commandPlanner = WorkbenchCommandPlanner()
        var mismatches: [String] = []

        for row in rows {
            let fixture = try matrix.fixture(for: row)
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
                mcpRegistration: matrix.registration(for: row),
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
            // F12a gap 5 — the checkpoint prompt can be delivered EITHER as the last
            // positional argv token (generic argv-reading TUIs) OR via
            // `.sendAfterLaunch` (Copilot, whose TUI ignores an argv prompt). The
            // matrix's `expectedRecoveryPrompt` means "a checkpoint prompt is
            // provided", independent of channel, so detection must consider both.
            let promptMarker = "Recover this Ouro Workbench terminal-agent session"
            let argvHasPrompt = planned.arguments.contains { $0.contains(promptMarker) }
            let sendAfterLaunchHasPrompt: Bool
            if case let .sendAfterLaunch(text) = planned.checkpointPromptDelivery {
                sendAfterLaunchHasPrompt = text.contains(promptMarker)
            } else {
                sendAfterLaunchHasPrompt = false
            }
            let includesCheckpointPrompt = argvHasPrompt || sendAfterLaunchHasPrompt
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

    func testAllFiveThousandScenarioRowsSatisfySurfaceChromeContracts() throws {
        let rows = try loadMatrix().rows
        var mismatches: [String] = []

        for row in rows {
            guard let surface = WorkbenchMatrixSurface(rawValue: row.surface) else {
                mismatches.append("\(row.caseID): unknown surface \(row.surface)")
                continue
            }

            let chrome = WorkbenchSurfaceChrome.contract(for: surface)
            if chrome.terminalContentOverlapsTrafficLights {
                mismatches.append("\(row.caseID): terminal content can render under traffic lights")
            }
            if chrome.floatingControlsOverlapTrafficLights {
                mismatches.append("\(row.caseID): floating controls can render under traffic lights")
            }
            if surface == .terminalFocus && !chrome.reservesTrafficLightRegion {
                mismatches.append("\(row.caseID): terminal focus must reserve the titlebar traffic-light region")
            }

            if mismatches.count >= 20 {
                break
            }
        }

        XCTAssertTrue(mismatches.isEmpty, mismatches.joined(separator: "\n"))
    }

    func testScenarioMatrixUsesUserShellIdentityWithoutLocalShellDefault() throws {
        let matrix = try loadMatrix()
        let rows = matrix.rows
        let shellRows = rows.filter { $0.terminal == "user_shell" }

        XCTAssertFalse(shellRows.isEmpty, "Matrix must keep explicit shell coverage under user_shell")
        XCTAssertFalse(rows.contains { $0.terminal == "local_shell" }, "local_shell must not remain canonical")
        for row in shellRows.prefix(20) {
            let fixture = try matrix.fixture(for: row)
            XCTAssertEqual(fixture.entry.kind, .shell, "\(row.caseID) must remain a shell fixture")
            XCTAssertEqual(fixture.entry.name, "User Shell")
        }
    }

    private func loadMatrix() throws -> WorkbenchScenarioMatrix {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return try WorkbenchScenarioMatrix.load(from: WorkbenchScenarioMatrix.defaultMatrixURL(packageRoot: packageRoot))
    }

    private func validRow() -> WorkbenchScenarioRow {
        try! WorkbenchScenarioRow(
            columns: [
                "WB-X",
                "claude",
                "running",
                "trusted_auto_session",
                "sidebar_dashboard",
                "registered",
                "available",
                "reattach",
                "false",
                "ready",
                "operator outcome",
                "boss outcome"
            ],
            lineNumber: 2
        )
    }

    private func writeMatrix(_ name: String, _ contents: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkbenchScenarioMatrixTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("\(name).tsv")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
