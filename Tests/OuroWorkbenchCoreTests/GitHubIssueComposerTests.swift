import XCTest
@testable import OuroWorkbenchCore

final class GitHubIssueComposerTests: XCTestCase {
    func testTitleUsesFirstMeaningfulLineWithPrefix() {
        let title = GitHubIssueComposer.title(note: "\n  Terminal froze on switch\nmore detail")
        XCTAssertEqual(title, "Bug: Terminal froze on switch")
    }

    func testTitleFallsBackWhenNoteIsEmpty() {
        XCTAssertEqual(GitHubIssueComposer.title(note: "   \n  "), "Bug: report from Ouro Workbench")
    }

    func testTitleIsCappedAndEllipsizedWithinLimit() {
        let title = GitHubIssueComposer.title(note: String(repeating: "word ", count: 50), maxLength: 40)
        XCTAssertLessThanOrEqual(title.count, 40)
        XCTAssertTrue(title.hasPrefix("Bug: "))
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testBodyAppendsBundleFooterPointingAtLocalPath() {
        let body = GitHubIssueComposer.body(reportMarkdown: "# Report\n\nbody\n", bundlePath: "/tmp/bug-reports/x")
        XCTAssertTrue(body.contains("# Report"))
        XCTAssertTrue(body.contains("`/tmp/bug-reports/x`"))
        XCTAssertTrue(body.contains("not uploaded here"))
    }

    func testBodyWithoutBundlePathIsUnchanged() {
        let markdown = "# Report\n\nbody\n"
        XCTAssertEqual(GitHubIssueComposer.body(reportMarkdown: markdown, bundlePath: nil), markdown)
        XCTAssertEqual(GitHubIssueComposer.body(reportMarkdown: markdown, bundlePath: ""), markdown)
    }

    func testDraftCombinesTitleAndBody() {
        let draft = GitHubIssueComposer.draft(
            note: "Crash on launch",
            reportMarkdown: "# Report\n",
            bundlePath: "/tmp/x"
        )
        XCTAssertEqual(draft.title, "Bug: Crash on launch")
        XCTAssertTrue(draft.body.contains("# Report"))
        XCTAssertTrue(draft.body.contains("/tmp/x"))
    }

    /// The issue title (from the raw note) and the bundle-path footer bypass the
    /// already-redacted `report.md`, so the draft must anonymize them itself when
    /// a redactor is supplied (#236) — username, home path, and agent names must
    /// not survive into either.
    func testDraftRedactsTitleAndBundlePathWhenRedactorSupplied() {
        let draft = GitHubIssueComposer.draft(
            note: "agent-zeta broke for jdoe",
            reportMarkdown: "# Report (already redacted)\n",
            bundlePath: "/Users/jdoe/Library/Application Support/Ouro Workbench/bug-reports/x",
            redactor: WorkbenchBugReportRedactor(),
            agentNames: ["agent-zeta"],
            homePath: "/Users/jdoe",
            username: "jdoe"
        )
        XCTAssertFalse(draft.title.contains("agent-zeta"))
        XCTAssertFalse(draft.title.contains("jdoe"))
        XCTAssertTrue(draft.title.contains("<agent>"))
        XCTAssertFalse(draft.body.contains("/Users/jdoe"), "home path leaked in footer")
        XCTAssertTrue(draft.body.contains("~/Library/Application Support"))
    }

    // MARK: - GitHubIssueFiler pure helpers

    func testParseIssueURLTakesLastHTTPSLine() {
        let output = """
        Creating issue in ourostack/ouro-workbench

        https://github.com/ourostack/ouro-workbench/issues/42
        """
        XCTAssertEqual(
            GitHubIssueFiler.parseIssueURL(from: output),
            "https://github.com/ourostack/ouro-workbench/issues/42"
        )
    }

    func testParseIssueURLReturnsNilWhenAbsent() {
        XCTAssertNil(GitHubIssueFiler.parseIssueURL(from: "could not create issue: not authenticated"))
    }

    func testResolveCLIPrefersKnownLocationsThenPath() {
        // A throwaway dir with an executable `gh` is found via the PATH fallback.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gh-resolve-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("gh")
        FileManager.default.createFile(atPath: fake.path, contents: Data("#!/bin/sh\n".utf8))
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let resolved = GitHubIssueFiler.resolveCLI(environment: ["PATH": dir.path])
        // On a machine with a real gh in a known location, that wins; otherwise
        // the PATH fallback finds our fake. Either way a gh is resolved.
        XCTAssertNotNil(resolved)
    }
}
