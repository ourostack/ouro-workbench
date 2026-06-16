import XCTest
@testable import OuroWorkbenchCore

final class BugReportWriterTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bugreport-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try FileManager.default.removeItem(at: tempRoot)
        }
    }

    private func write(
        screenshot: Data? = Data([0x89, 0x50, 0x4E, 0x47]),
        diagnostics: URL? = nil,
        diagnosticsError: String? = nil
    ) throws -> BugReportBundle {
        try BugReportWriter.write(
            into: tempRoot.appendingPathComponent("report-dir", isDirectory: true),
            note: "It broke",
            appName: "Ouro Workbench",
            appVersion: "0.1.105",
            buildHash: "abc1234",
            osVersion: "macOS 15.2",
            generatedAt: Date(),
            bossName: "slugger",
            bossWatchEnabled: true,
            autoAdvanceEnabled: true,
            sessions: [],
            recentDecisions: [],
            recentActions: [],
            screenshotPNG: screenshot,
            diagnosticsArchiveURL: diagnostics,
            diagnosticsError: diagnosticsError
        )
    }

    func testWritesReportAndScreenshot() throws {
        let bundle = try write()
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: bundle.reportURL.path))
        XCTAssertTrue(fm.fileExists(atPath: bundle.directoryURL.appendingPathComponent("screenshot.png").path))
        XCTAssertTrue(bundle.attachmentNames.contains("screenshot.png"))
        let md = try String(contentsOf: bundle.reportURL, encoding: .utf8)
        XCTAssertTrue(md.contains("It broke"))
        XCTAssertTrue(md.contains("- `screenshot.png`"))
    }

    func testMissingScreenshotBecomesWarning() throws {
        let bundle = try write(screenshot: nil)
        XCTAssertFalse(bundle.attachmentNames.contains("screenshot.png"))
        XCTAssertTrue(bundle.warnings.contains { $0.contains("screenshot") })
        let md = try String(contentsOf: bundle.reportURL, encoding: .utf8)
        XCTAssertTrue(md.contains("## Collection warnings"))
    }

    func testCopiesDiagnosticsArchiveIntoBundle() throws {
        let archive = tempRoot.appendingPathComponent("source-diagnostics.zip")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try Data("zip-bytes".utf8).write(to: archive)

        let bundle = try write(diagnostics: archive)
        let copied = bundle.directoryURL.appendingPathComponent("diagnostics.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertTrue(bundle.attachmentNames.contains("diagnostics.zip"))
        XCTAssertEqual(try Data(contentsOf: copied), Data("zip-bytes".utf8))
    }

    func testDiagnosticsArchiveReplacesExistingBundleArchive() throws {
        let archive = tempRoot.appendingPathComponent("source-diagnostics.zip")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let reportDir = tempRoot.appendingPathComponent("report-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: reportDir.appendingPathComponent("diagnostics.zip"))
        try Data("new".utf8).write(to: archive)

        let bundle = try write(diagnostics: archive)
        let copied = bundle.directoryURL.appendingPathComponent("diagnostics.zip")

        XCTAssertEqual(try Data(contentsOf: copied), Data("new".utf8))
    }

    func testWorkbenchPathsBugReportsURLUsesAppSupportRoot() {
        let paths = WorkbenchPaths(rootURL: tempRoot)
        XCTAssertEqual(paths.bugReportsURL, tempRoot.appendingPathComponent("bug-reports", isDirectory: true))
    }

    func testDiagnosticsFailureBecomesWarning() throws {
        let bundle = try write(diagnostics: nil, diagnosticsError: "script missing")
        XCTAssertFalse(bundle.attachmentNames.contains("diagnostics.zip"))
        XCTAssertTrue(bundle.warnings.contains { $0.contains("script missing") })
    }
}
