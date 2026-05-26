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

    func testLocatesRepoDiagnosticsScriptWhenBundleScriptIsMissing() throws {
        let repo = temporaryDirectory.appendingPathComponent("repo", isDirectory: true)
        let repoScripts = repo.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: repoScripts, withIntermediateDirectories: true)

        let repoScript = repoScripts.appendingPathComponent("collect-support-diagnostics.sh")
        try writeExecutableScript(at: repoScript)

        let runner = SupportDiagnosticsRunner(resourceDirectory: nil, currentDirectory: repo)

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
        printf 'Wrote diagnostics: \(archive.path)\\n'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let result = try SupportDiagnosticsRunner(resourceDirectory: resources, currentDirectory: temporaryDirectory).run()

        XCTAssertEqual(result.archiveURL.path, archive.path)
        XCTAssertTrue(result.output.contains("Wrote diagnostics"))
    }

    private func writeExecutableScript(at url: URL) throws {
        try """
        #!/usr/bin/env bash
        exit 0
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
