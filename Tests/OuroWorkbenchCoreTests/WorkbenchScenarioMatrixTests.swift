import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchScenarioMatrixTests: XCTestCase {
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

    private func loadMatrix() throws -> WorkbenchScenarioMatrix {
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return try WorkbenchScenarioMatrix.load(from: WorkbenchScenarioMatrix.defaultMatrixURL(packageRoot: packageRoot))
    }
}
