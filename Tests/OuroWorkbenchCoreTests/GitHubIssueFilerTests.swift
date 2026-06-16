import XCTest
@testable import OuroWorkbenchCore

final class GitHubIssueFilerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHubIssueFilerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testResolveCLIFindsExecutableOnInjectedPathAndReturnsNilWithoutPATH() throws {
        let bin = tempRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let gh = try writeExecutable(named: "gh", contents: "#!/bin/sh\nexit 0\n", in: bin)

        let fileManager = StubExecutableFileManager(executablePaths: [gh.path])
        XCTAssertEqual(
            GitHubIssueFiler.resolveCLI(fileManager: fileManager, environment: ["PATH": bin.path])?.standardizedFileURL,
            gh.standardizedFileURL
        )
        XCTAssertNil(GitHubIssueFiler.resolveCLI(fileManager: fileManager, environment: [:]))
    }

    private final class StubExecutableFileManager: FileManager, @unchecked Sendable {
        private let executablePaths: Set<String>

        init(executablePaths: Set<String>) {
            self.executablePaths = executablePaths
            super.init()
        }

        override func isExecutableFile(atPath path: String) -> Bool {
            executablePaths.contains(path)
        }
    }

    func testIssueComposerTitleFallsBackTruncatesAndBodyFooterIsOptional() {
        XCTAssertEqual(GitHubIssueComposer.title(note: " \n\t ", prefix: "Bug:", maxLength: 80), "Bug: report from Ouro Workbench")

        let title = GitHubIssueComposer.title(note: String(repeating: "abcdef ", count: 20), prefix: "Bug:", maxLength: 20)
        XCTAssertEqual(title.count, 20)
        XCTAssertTrue(title.hasPrefix("Bug: "))
        XCTAssertTrue(title.hasSuffix("…"))

        XCTAssertEqual(GitHubIssueComposer.body(reportMarkdown: "body", bundlePath: ""), "body")
        XCTAssertEqual(
            GitHubIssueComposer.body(reportMarkdown: "body\n", bundlePath: "/bundle"),
            "body\n\n---\nThe screenshot and diagnostics zip are in the local report bundle (not uploaded here): `/bundle`\n"
        )
    }

    func testParseIssueURLUsesLastTrimmedHTTPSLineOnly() {
        let output = """
        warning
          https://github.com/org/repo/issues/1
        done
        https://github.com/org/repo/issues/2
        """
        XCTAssertEqual(GitHubIssueFiler.parseIssueURL(from: output), "https://github.com/org/repo/issues/2")
        XCTAssertNil(GitHubIssueFiler.parseIssueURL(from: "http://example.com\nnot a url"))
    }

    func testFilingReadsReportRetriesWithoutMissingLabelAndReturnsIssueURL() throws {
        let report = tempRoot.appendingPathComponent("report.md")
        try "Report body\n".write(to: report, atomically: true, encoding: .utf8)
        let state = tempRoot.appendingPathComponent("gh-state")
        let gh = try writeExecutable(
            named: "gh",
            contents: """
            #!/bin/sh
            state="\(state.path)"
            if [ ! -f "$state" ]; then
              echo first > "$state"
              echo "label bug does not exist" >&2
              exit 1
            fi
            case "$*" in
              *"--label bug"*) echo "label was retried" >&2; exit 1 ;;
            esac
            echo "https://github.com/example/repo/issues/42"
            """,
            in: tempRoot
        )

        let result = GitHubIssueFiler.file(
            reportURL: report,
            bundlePath: "/bundle",
            note: "Crash on launch",
            repo: "example/repo",
            cliURL: gh
        )

        XCTAssertEqual(result, .success("https://github.com/example/repo/issues/42"))
    }

    func testFilingReportsReadLaunchCommandAndNoURLFailures() throws {
        let missingReport = tempRoot.appendingPathComponent("missing.md")
        let nonExecutable = tempRoot.appendingPathComponent("not-gh")
        try "".write(to: nonExecutable, atomically: true, encoding: .utf8)
        XCTAssertFailure(
            GitHubIssueFiler.file(reportURL: missingReport, bundlePath: "/bundle", note: "n", repo: "r", cliURL: nonExecutable),
            matching: .readReportFailed("")
        )

        let report = tempRoot.appendingPathComponent("report.md")
        try "Body".write(to: report, atomically: true, encoding: .utf8)
        XCTAssertFailure(
            GitHubIssueFiler.file(reportURL: report, bundlePath: "/bundle", note: "n", repo: "r", cliURL: nonExecutable),
            matching: .launchFailed("")
        )

        let failing = try writeExecutable(named: "gh-failing", contents: "#!/bin/sh\nexit 7\n", in: tempRoot)
        XCTAssertEqual(
            GitHubIssueFiler.file(reportURL: report, bundlePath: "/bundle", note: "n", repo: "r", cliURL: failing),
            .failure(.commandFailed("gh exited with status 7"))
        )

        let failingWithOutput = try writeExecutable(named: "gh-failing-output", contents: "#!/bin/sh\necho boom\nexit 7\n", in: tempRoot)
        XCTAssertEqual(
            GitHubIssueFiler.file(reportURL: report, bundlePath: "/bundle", note: "n", repo: "r", cliURL: failingWithOutput),
            .failure(.commandFailed("boom"))
        )

        XCTAssertEqual(
            GitHubIssueFiler.file(reportURL: report, bundlePath: "/bundle", note: "n", repo: "r", cliURL: nil, fileManager: StubExecutableFileManager(executablePaths: [])),
            .failure(.cliMissing)
        )

        let missingBodyDir = tempRoot.appendingPathComponent("missing-dir", isDirectory: true)
        XCTAssertFailure(
            GitHubIssueFiler.file(reportURL: report, bundlePath: "/bundle", note: "n", repo: "r", cliURL: failing, bodyDirectory: missingBodyDir),
            matching: .launchFailed("")
        )

        let noURL = try writeExecutable(named: "gh-no-url", contents: "#!/bin/sh\necho created\n", in: tempRoot)
        XCTAssertEqual(
            GitHubIssueFiler.file(reportURL: report, bundlePath: "/bundle", note: "n", repo: "r", cliURL: noURL),
            .failure(.noURL("created"))
        )
    }

    func testFilingErrorDescriptionsAreOperatorReadable() {
        XCTAssertEqual(GitHubIssueFilingError.cliMissing.errorDescription?.contains("GitHub CLI"), true)
        XCTAssertEqual(GitHubIssueFilingError.readReportFailed("denied").errorDescription, "Could not read the report: denied")
        XCTAssertEqual(GitHubIssueFilingError.launchFailed("denied").errorDescription, "Could not start gh: denied")
        XCTAssertEqual(GitHubIssueFilingError.commandFailed("bad").errorDescription, "gh issue create failed: bad")
        XCTAssertEqual(GitHubIssueFilingError.noURL("created").errorDescription, "gh did not report an issue URL: created")
    }

    private func writeExecutable(named name: String, contents: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func XCTAssertFailure(
        _ result: Result<String, GitHubIssueFilingError>,
        matching expected: GitHubIssueFilingError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .failure(error) = result else {
            XCTFail("Expected failure, got \(result)", file: file, line: line)
            return
        }
        switch (error, expected) {
        case (.readReportFailed, .readReportFailed),
             (.launchFailed, .launchFailed):
            break
        default:
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }
}
