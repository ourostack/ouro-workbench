import XCTest
@testable import OuroWorkbenchCore

final class ExecutableHealthTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExecutableHealthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testFindsExecutableOnResolvedPath() throws {
        let executableURL = temporaryDirectory.appendingPathComponent("codex")
        try Data("#!/bin/sh\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        let checker = ExecutableHealthChecker(
            environment: TerminalEnvironment(values: ["PATH": temporaryDirectory.path])
        )

        let health = checker.health(for: "codex")

        XCTAssertEqual(health.status, .available)
        XCTAssertEqual(health.resolvedPath, executableURL.path)
    }

    func testReportsMissingExecutable() {
        let checker = ExecutableHealthChecker(
            environment: TerminalEnvironment(values: ["PATH": temporaryDirectory.path])
        )

        let health = checker.health(for: "missing-tool")

        XCTAssertEqual(health.status, .missing)
        XCTAssertNil(health.resolvedPath)
    }

    func testReportsNotExecutableAbsolutePath() throws {
        let executableURL = temporaryDirectory.appendingPathComponent("claude")
        try Data("#!/bin/sh\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: executableURL.path)
        let checker = ExecutableHealthChecker()

        let health = checker.health(for: executableURL.path)

        XCTAssertEqual(health.status, .notExecutable)
        XCTAssertEqual(health.resolvedPath, executableURL.path)
    }
}
