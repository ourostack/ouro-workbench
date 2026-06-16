import XCTest
@testable import OuroWorkbenchCore

final class SupportDiagnosticsRunnerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SupportDiagnosticsRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testLocatesBundledDiagnosticsScriptBeforeRepoScript() throws {
        let resources = temporaryDirectory.appendingPathComponent("Resources", isDirectory: true)
        let repo = temporaryDirectory.appendingPathComponent("repo", isDirectory: true)
        let repoScripts = repo.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoScripts, withIntermediateDirectories: true)

        let bundled = resources.appendingPathComponent("collect-support-diagnostics.sh")
        let repoScript = repoScripts.appendingPathComponent("collect-support-diagnostics.sh")
        try writeExecutableScript(at: bundled)
        try writeExecutableScript(at: repoScript)

        let runner = SupportDiagnosticsRunner(resourceDirectory: resources, currentDirectory: repo)

        XCTAssertEqual(runner.scriptURL()?.standardizedFileURL, bundled.standardizedFileURL)
    }

    func testCandidateScriptURLsDeduplicateSameResourceAndRepoDirectory() {
        let runner = SupportDiagnosticsRunner(resourceDirectory: temporaryDirectory.appendingPathComponent("scripts"), currentDirectory: temporaryDirectory)

        let paths = runner.candidateScriptURLs.map(\.standardizedFileURL.path)

        XCTAssertEqual(Set(paths).count, paths.count)
        XCTAssertEqual(paths.count, 2)
    }

    func testLocatesRepoDiagnosticsScriptWhenBundleScriptIsMissing() throws {
        let repo = temporaryDirectory.appendingPathComponent("repo", isDirectory: true)
        let repoScripts = repo.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: repoScripts, withIntermediateDirectories: true)

        let repoScript = repoScripts.appendingPathComponent("collect-support-diagnostics.sh")
        try writeExecutableScript(at: repoScript)

        let runner = SupportDiagnosticsRunner(resourceDirectory: nil, currentDirectory: repo)

        XCTAssertEqual(runner.scriptURL()?.standardizedFileURL, repoScript.standardizedFileURL)
    }

    func testIgnoresNonExecutableDiagnosticsScriptCandidates() throws {
        let resources = temporaryDirectory.appendingPathComponent("Resources", isDirectory: true)
        let repo = temporaryDirectory.appendingPathComponent("repo", isDirectory: true)
        let repoScripts = repo.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoScripts, withIntermediateDirectories: true)

        let nonExecutable = resources.appendingPathComponent("collect-support-diagnostics.sh")
        try "not executable".write(to: nonExecutable, atomically: true, encoding: .utf8)

        let repoScript = repoScripts.appendingPathComponent("collect-support-diagnostics.sh")
        try writeExecutableScript(at: repoScript)

        let runner = SupportDiagnosticsRunner(resourceDirectory: resources, currentDirectory: repo)

        XCTAssertEqual(runner.scriptURL()?.standardizedFileURL, repoScript.standardizedFileURL)
    }

    func testParsesDiagnosticsArchivePathFromOutput() {
        let output = """
        preparing bundle
        Wrote diagnostics: /tmp/ouro-workbench-diagnostics.zip
        """

        XCTAssertEqual(
            SupportDiagnosticsRunner.parseArchiveURL(from: output)?.path,
            "/tmp/ouro-workbench-diagnostics.zip"
        )
    }

    func testRunsDiagnosticsScriptAndReturnsArchiveURL() throws {
        let resources = temporaryDirectory.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let script = resources.appendingPathComponent("collect-support-diagnostics.sh")
        let archive = temporaryDirectory.appendingPathComponent("diag.zip")
        try """
        #!/usr/bin/env bash
        set -euo pipefail
        printf 'diagnostics\\n' > \(ShellArgumentEscaper.quote(archive.path))
        printf 'Wrote diagnostics: \(archive.path)\\n'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let result = try SupportDiagnosticsRunner(resourceDirectory: resources, currentDirectory: temporaryDirectory).run()

        XCTAssertEqual(result.archiveURL.path, archive.path)
        XCTAssertTrue(result.output.contains("Wrote diagnostics"))
    }

    func testRunFailsWhenScriptIsMissing() {
        let runner = SupportDiagnosticsRunner(resourceDirectory: nil, currentDirectory: temporaryDirectory)

        XCTAssertThrowsError(try runner.run()) { error in
            XCTAssertEqual(error as? SupportDiagnosticsRunnerError, .scriptMissing(runner.candidateScriptURLs.map(\.path)))
            XCTAssertTrue(error.localizedDescription.contains("Support diagnostics helper is missing."))
        }
    }

    func testRunFailsWhenScriptExitsNonZero() throws {
        let resources = temporaryDirectory.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let script = resources.appendingPathComponent("collect-support-diagnostics.sh")
        try """
        #!/usr/bin/env bash
        printf 'boom\\n'
        exit 42
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        XCTAssertThrowsError(try SupportDiagnosticsRunner(resourceDirectory: resources, currentDirectory: temporaryDirectory).run()) { error in
            guard case let .failed(status, output) = error as? SupportDiagnosticsRunnerError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(status, 42)
            XCTAssertTrue(output.contains("boom"))
            XCTAssertTrue(error.localizedDescription.contains("Support diagnostics exited with status 42"))
        }
    }

    func testRunReportsLaunchFailureWhenExecutableCandidateIsDirectory() throws {
        let resources = temporaryDirectory.appendingPathComponent("Resources", isDirectory: true)
        let scriptDirectory = resources.appendingPathComponent("collect-support-diagnostics.sh", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)

        XCTAssertThrowsError(try SupportDiagnosticsRunner(resourceDirectory: resources, currentDirectory: temporaryDirectory).run()) { error in
            guard case .launchFailed = error as? SupportDiagnosticsRunnerError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRunFallsBackToEmptyOutputWhenScriptEmitsInvalidUTF8() throws {
        let resources = temporaryDirectory.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let script = resources.appendingPathComponent("collect-support-diagnostics.sh")
        try """
        #!/usr/bin/env bash
        printf '\\xff'
        exit 5
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        XCTAssertThrowsError(try SupportDiagnosticsRunner(resourceDirectory: resources, currentDirectory: temporaryDirectory).run()) { error in
            XCTAssertEqual(error as? SupportDiagnosticsRunnerError, .failed(status: 5, output: ""))
        }
    }

    func testRunFailsWhenScriptDoesNotReportArchivePath() throws {
        let resources = temporaryDirectory.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let script = resources.appendingPathComponent("collect-support-diagnostics.sh")
        try """
        #!/usr/bin/env bash
        printf 'done without archive\\n'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        XCTAssertThrowsError(try SupportDiagnosticsRunner(resourceDirectory: resources, currentDirectory: temporaryDirectory).run()) { error in
            XCTAssertEqual(error as? SupportDiagnosticsRunnerError, .archivePathMissing("done without archive\n"))
            XCTAssertTrue(error.localizedDescription.contains("did not report an archive path"))
        }
    }

    func testRunFailsWhenReportedArchiveIsMissing() throws {
        let resources = temporaryDirectory.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let script = resources.appendingPathComponent("collect-support-diagnostics.sh")
        let archive = temporaryDirectory.appendingPathComponent("missing.zip")
        try """
        #!/usr/bin/env bash
        printf 'Wrote diagnostics: \(archive.path)\\n'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        XCTAssertThrowsError(try SupportDiagnosticsRunner(resourceDirectory: resources, currentDirectory: temporaryDirectory).run()) { error in
            XCTAssertEqual(error as? SupportDiagnosticsRunnerError, .archiveMissing(archive.path))
            XCTAssertEqual(error.localizedDescription, "Support diagnostics reported a missing archive: \(archive.path)")
        }
    }

    func testParseArchiveURLIgnoresNonMatchingAndBlankArchiveLines() {
        XCTAssertNil(SupportDiagnosticsRunner.parseArchiveURL(from: "no archive here"))
        XCTAssertNil(SupportDiagnosticsRunner.parseArchiveURL(from: "Wrote diagnostics:    \n"))
    }

    func testLaunchFailedDescriptionIncludesUnderlyingMessage() {
        XCTAssertEqual(
            SupportDiagnosticsRunnerError.launchFailed("permission denied").errorDescription,
            "Support diagnostics could not start: permission denied"
        )
    }

    func testDefaultOutputDirectoryUsesApplicationSupport() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        XCTAssertEqual(
            SupportDiagnosticsRunner.defaultOutputDirectory(homeDirectory: home).path,
            "/Users/example/Library/Application Support/OuroWorkbench/support-diagnostics"
        )
    }

    private func writeExecutableScript(at url: URL) throws {
        try """
        #!/usr/bin/env bash
        exit 0
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
