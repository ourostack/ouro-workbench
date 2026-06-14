import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchLaunchDiagnosticsTests: XCTestCase {
    func testParseEmptyArgumentsUsesDefaultOptions() throws {
        let diagnostics = try WorkbenchLaunchDiagnostics.parse(["OuroWorkbench"])

        XCTAssertNil(diagnostics.appSupportRoot)
        XCTAssertFalse(diagnostics.autoLaunchResumableForE2E)
        XCTAssertNil(diagnostics.action)
        XCTAssertEqual(diagnostics.passthroughArguments, [])
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
            "--factory-reset-for-e2e"
        ])

        XCTAssertEqual(diagnostics.action, .factoryResetForE2E)
    }

    func testParseRequiresAppSupportRootPath() {
        XCTAssertThrowsError(try WorkbenchLaunchDiagnostics.parse([
            "OuroWorkbench",
            "--app-support-root"
        ]))
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
