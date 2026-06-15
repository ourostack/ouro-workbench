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

    func testReportsEmptyExecutableAsMissingConfiguration() {
        let checker = ExecutableHealthChecker(
            environment: TerminalEnvironment(values: ["PATH": temporaryDirectory.path])
        )

        let health = checker.health(for: " \n\t ")

        XCTAssertEqual(health.status, .missing)
        XCTAssertNil(health.resolvedPath)
        XCTAssertEqual(health.detail, "No executable configured.")
    }

    func testReportsMissingAbsolutePathWithResolvedPath() {
        let missingPath = temporaryDirectory.appendingPathComponent("absent-tool").path
        let checker = ExecutableHealthChecker()

        let health = checker.health(for: missingPath)

        XCTAssertEqual(health.status, .missing)
        XCTAssertEqual(health.resolvedPath, missingPath)
        XCTAssertEqual(health.detail, "\(missingPath) does not exist.")
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

    func testGenericShellScriptHealthTargetsShellExecutable() {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Script",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            arguments: ["-lc", "i=0; while true; do echo \"$i\"; i=$((i+1)); done"],
            workingDirectory: "/tmp",
            trust: .trusted,
            autoResume: true
        )

        XCTAssertEqual(ExecutableHealthTarget.executable(for: entry), "/bin/zsh")
    }

    func testShellWrappedKnownAgentHealthTargetsDetectedExecutable() {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Claude",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            arguments: ["-lc", "claude --dangerously-skip-permissions"],
            workingDirectory: "/tmp",
            trust: .trusted,
            autoResume: true
        )

        XCTAssertEqual(ExecutableHealthTarget.executable(for: entry), "claude")
    }
}
