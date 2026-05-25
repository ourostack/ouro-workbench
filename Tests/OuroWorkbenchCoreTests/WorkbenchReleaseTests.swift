import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchReleaseTests: XCTestCase {
    func testReleaseVersionMatchesVersionFile() throws {
        let versionFile = repoRoot().appendingPathComponent("VERSION")
        let version = try String(contentsOf: versionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(WorkbenchRelease.version, version)
    }

    func testReleaseMetadataIsValidForNativeBundleAndMCP() {
        XCTAssertEqual(WorkbenchRelease.appName, "Ouro Workbench")
        XCTAssertEqual(WorkbenchRelease.bundleIdentifier, "com.ourostack.workbench")
        XCTAssertEqual(WorkbenchRelease.bundleExecutable, "OuroWorkbench")
        XCTAssertEqual(WorkbenchRelease.mcpExecutable, "OuroWorkbenchMCP")
        XCTAssertEqual(WorkbenchRelease.mcpServerName, "ouro-workbench")
        XCTAssertEqual(WorkbenchRelease.minimumMacOSVersion, "14.0")
        XCTAssertTrue(WorkbenchRelease.version.range(of: #"^\d+\.\d+\.\d+([-.][0-9A-Za-z.]+)?$"#, options: .regularExpression) != nil)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
