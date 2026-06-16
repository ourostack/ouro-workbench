import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchLaunchDiagnosticsTests: XCTestCase {
    func testParseEmptyArgumentsUsesDefaultOptions() throws {
        let diagnostics = try WorkbenchLaunchDiagnostics.parse(["OuroWorkbench"])

        XCTAssertNil(diagnostics.appSupportRoot)
        XCTAssertFalse(diagnostics.autoLaunchResumableForE2E)
        XCTAssertNil(diagnostics.action)
        XCTAssertEqual(diagnostics.passthroughArguments, [])

        let processless = try WorkbenchLaunchDiagnostics.parse([])
        XCTAssertNil(processless.action)
        XCTAssertEqual(processless.passthroughArguments, [])
    }

    func testParseAppSupportRootAndAutoLaunchOverride() throws {
        let diagnostics = try WorkbenchLaunchDiagnostics.parse([
            "OuroWorkbench",
            "--app-support-root",
            "/tmp/ouro-workbench",
            "--auto-launch-resumable-for-e2e"
        ])

        XCTAssertEqual(diagnostics.appSupportRoot?.path, "/tmp/ouro-workbench")
        XCTAssertTrue(diagnostics.autoLaunchResumableForE2E)
        XCTAssertNil(diagnostics.action)
        XCTAssertEqual(diagnostics.passthroughArguments, [])
    }

    func testParseFactoryResetAction() throws {
        let diagnostics = try WorkbenchLaunchDiagnostics.parse([
            "OuroWorkbench",
            "--app-support-root",
            "/tmp/ouro-workbench",
            "--factory-reset-for-e2e"
        ])

        XCTAssertEqual(diagnostics.appSupportRoot?.path, "/tmp/ouro-workbench")
        XCTAssertEqual(diagnostics.action, .factoryResetForE2E)
    }

    func testParseFactoryResetRequiresAppSupportRoot() {
        XCTAssertThrowsError(try WorkbenchLaunchDiagnostics.parse([
            "OuroWorkbench",
            "--factory-reset-for-e2e"
        ])) { error in
            XCTAssertEqual(error as? WorkbenchLaunchDiagnostics.ParseError, .factoryResetRequiresAppSupportRoot)
            XCTAssertEqual(error.localizedDescription, "--factory-reset-for-e2e requires --app-support-root")
        }
    }

    func testParseDumpRecentSessionsDiagnostic() throws {
        let diagnostics = try WorkbenchLaunchDiagnostics.parse([
            "OuroWorkbench",
            "--dump-recent-sessions-json"
        ])

        XCTAssertEqual(diagnostics.action, .dumpRecentSessions(scanHomeRoot: nil))
    }

    func testParseDumpRecentSessionsDiagnosticWithScanHomeRoot() throws {
        let diagnostics = try WorkbenchLaunchDiagnostics.parse([
            "OuroWorkbench",
            "--dump-recent-sessions-json",
            "--scan-home-root",
            "/tmp/harness-home"
        ])

        XCTAssertEqual(
            diagnostics.action,
            .dumpRecentSessions(scanHomeRoot: URL(fileURLWithPath: "/tmp/harness-home", isDirectory: true))
        )
    }

    func testParseScanHomeRootRequiresPath() {
        XCTAssertThrowsError(try WorkbenchLaunchDiagnostics.parse([
            "OuroWorkbench",
            "--dump-recent-sessions-json",
            "--scan-home-root"
        ])) { error in
            XCTAssertEqual(error as? WorkbenchLaunchDiagnostics.ParseError, .missingValue("--scan-home-root"))
            XCTAssertEqual(error.localizedDescription, "--scan-home-root requires a value")
        }
    }

    func testParseRequiresAppSupportRootPath() {
        XCTAssertThrowsError(try WorkbenchLaunchDiagnostics.parse([
            "OuroWorkbench",
            "--app-support-root"
        ])) { error in
            XCTAssertEqual(error as? WorkbenchLaunchDiagnostics.ParseError, .missingValue("--app-support-root"))
            XCTAssertEqual(error.localizedDescription, "--app-support-root requires a value")
        }
    }

    func testParseWriteE2EStateRequiresFixtureAndPath() {
        XCTAssertThrowsError(try WorkbenchLaunchDiagnostics.parse([
            "OuroWorkbench",
            "--write-e2e-state"
        ])) { error in
            XCTAssertEqual(error as? WorkbenchLaunchDiagnostics.ParseError, .missingValue("--write-e2e-state"))
        }

        XCTAssertThrowsError(try WorkbenchLaunchDiagnostics.parse([
            "OuroWorkbench",
            "--write-e2e-state",
            "sidebar-session-controls"
        ])) { error in
            XCTAssertEqual(error as? WorkbenchLaunchDiagnostics.ParseError, .missingValue("sidebar-session-controls"))
        }
    }

    func testParseWriteE2EStateKeepsUnknownFixtureAsPassthrough() throws {
        let diagnostics = try WorkbenchLaunchDiagnostics.parse([
            "OuroWorkbench",
            "--write-e2e-state",
            "unknown-fixture",
            "/tmp/state.json"
        ])

        XCTAssertNil(diagnostics.action)
        XCTAssertEqual(diagnostics.passthroughArguments, ["--write-e2e-state", "unknown-fixture", "/tmp/state.json"])
    }

    func testParseKeepsUnknownArgumentsForExistingLaunchHandling() throws {
        let diagnostics = try WorkbenchLaunchDiagnostics.parse([
            "OuroWorkbench",
            "--smoke-launch",
            "--mystery"
        ])

        XCTAssertEqual(diagnostics.passthroughArguments, ["--smoke-launch", "--mystery"])
    }
}
