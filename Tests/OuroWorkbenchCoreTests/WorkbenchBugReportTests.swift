import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchBugReportTests: XCTestCase {
    private let redactor = WorkbenchBugReportRedactor()

    // MARK: - Redactor: home path

    func testRedactHomePathBecomesTilde() {
        let out = redactor.redact(
            "logs are in /Users/microsoft/Library and /Users/microsoft too",
            agentNames: [],
            homePath: "/Users/microsoft",
            username: "microsoft"
        )
        XCTAssertFalse(out.contains("/Users/microsoft"))
        XCTAssertTrue(out.contains("~/Library"))
        // every occurrence replaced
        XCTAssertEqual(out.components(separatedBy: "~").count - 1, 2)
    }

    func testEmptyHomePathIsNoOp() {
        // An empty homePath must NOT inject "~" into the text.
        let out = redactor.redact(
            "a plain sentence with no secrets",
            agentNames: [],
            homePath: "",
            username: "bob"
        )
        XCTAssertEqual(out, "a plain sentence with no secrets")
        XCTAssertFalse(out.contains("~"))
    }

    // MARK: - Redactor: username

    func testRedactUsernameWholeWordCaseInsensitive() {
        let out = redactor.redact(
            "user microsoft and Microsoft logged in",
            agentNames: [],
            homePath: "",
            username: "microsoft"
        )
        XCTAssertTrue(out.contains("<user>"))
        XCTAssertFalse(out.lowercased().contains("microsoft"))
        XCTAssertEqual(out.components(separatedBy: "<user>").count - 1, 2)
    }

    func testUsernameDoesNotMatchSubstring() {
        // "microsoftware" must not be partially redacted — whole-word only.
        let out = redactor.redact(
            "we ship microsoftware here",
            agentNames: [],
            homePath: "",
            username: "microsoft"
        )
        XCTAssertEqual(out, "we ship microsoftware here")
    }

    func testEmptyUsernameIsNoOp() {
        let out = redactor.redact(
            "nothing to see",
            agentNames: [],
            homePath: "/Users/x",
            username: ""
        )
        XCTAssertEqual(out, "nothing to see")
        XCTAssertFalse(out.contains("<user>"))
    }

    // MARK: - Redactor: agent names

    func testRedactAgentNameWholeWordCaseInsensitive() {
        let out = redactor.redact(
            "Agent Doris and doris both failed",
            agentNames: ["Doris"],
            homePath: "",
            username: ""
        )
        XCTAssertFalse(out.lowercased().contains("doris"))
        XCTAssertEqual(out.components(separatedBy: "<agent>").count - 1, 2)
    }

    func testAgentNameDoesNotMatchSubstring() {
        // "Dorishire" must not be partially redacted.
        let out = redactor.redact(
            "Dorishire is a place",
            agentNames: ["Doris"],
            homePath: "",
            username: ""
        )
        XCTAssertEqual(out, "Dorishire is a place")
    }

    func testLongerAgentNamesProcessedFirst() {
        // "Doris Mae" must be redacted as one agent, not leave "Mae" partially handled.
        let out = redactor.redact(
            "Doris Mae and Doris reported",
            agentNames: ["Doris", "Doris Mae"],
            homePath: "",
            username: ""
        )
        XCTAssertFalse(out.contains("Doris"))
        XCTAssertFalse(out.contains("Mae"))
        // "Doris Mae" → one <agent>; standalone "Doris" → one <agent>
        XCTAssertEqual(out.components(separatedBy: "<agent>").count - 1, 2)
    }

    func testEmptyAgentNameEntryIsSkipped() {
        // A blank entry in the list must not blow up or inject markers everywhere.
        let out = redactor.redact(
            "hello world",
            agentNames: ["", "  "],
            homePath: "",
            username: ""
        )
        XCTAssertEqual(out, "hello world")
    }

    // MARK: - Redactor: token / secret patterns

    func testRedactVaultToken() {
        let out = redactor.redact("key=vault_abc123XYZ done", agentNames: [], homePath: "", username: "")
        XCTAssertTrue(out.contains("<redacted>"))
        XCTAssertFalse(out.contains("vault_abc123XYZ"))
    }

    func testRedactGitHubTokens() {
        for tok in ["ghp_AAAA1111bbbb", "gho_zzzz9999", "ghu_token", "ghr_token", "ghs_token"] {
            let out = redactor.redact("token \(tok) end", agentNames: [], homePath: "", username: "")
            XCTAssertTrue(out.contains("<redacted>"), "expected \(tok) redacted")
            XCTAssertFalse(out.contains(tok), "expected \(tok) gone")
        }
    }

    func testRedactBearerToken() {
        let out = redactor.redact("Authorization: Bearer abcDEF.token-123", agentNames: [], homePath: "", username: "")
        XCTAssertTrue(out.contains("<redacted>"))
        XCTAssertFalse(out.contains("abcDEF.token-123"))
    }

    func testRedactLongStandaloneToken() {
        // 40 chars of token-alphabet — a standalone secret-shaped blob.
        let secret = "ABCDabcd0123456789ABCDabcd0123456789ABCD"
        XCTAssertEqual(secret.count, 40)
        let out = redactor.redact("blob \(secret) tail", agentNames: [], homePath: "", username: "")
        XCTAssertTrue(out.contains("<redacted>"))
        XCTAssertFalse(out.contains(secret))
    }

    func testShortTokensAreNotRedacted() {
        // A 16-char run is below the 32-char floor — must survive.
        let out = redactor.redact("short ABCDabcd01234567 stays", agentNames: [], homePath: "", username: "")
        XCTAssertEqual(out, "short ABCDabcd01234567 stays")
    }

    // MARK: - Redactor: email

    func testRedactEmail() {
        let out = redactor.redact("ping me at jane.doe@example.com please", agentNames: [], homePath: "", username: "")
        XCTAssertTrue(out.contains("<email>"))
        XCTAssertFalse(out.contains("jane.doe@example.com"))
    }

    // MARK: - Redactor: combined / ordering

    func testCombinedRedactionAppliesAllKinds() {
        let out = redactor.redact(
            "microsoft ran Doris at /Users/microsoft with ghp_secrettoken and mail a@b.co",
            agentNames: ["Doris"],
            homePath: "/Users/microsoft",
            username: "microsoft"
        )
        XCTAssertTrue(out.contains("<user>"))
        XCTAssertTrue(out.contains("<agent>"))
        XCTAssertTrue(out.contains("~"))
        XCTAssertTrue(out.contains("<redacted>"))
        XCTAssertTrue(out.contains("<email>"))
        XCTAssertFalse(out.contains("/Users/microsoft"))
        XCTAssertFalse(out.contains("ghp_secrettoken"))
        XCTAssertFalse(out.contains("a@b.co"))
    }

    func testHomePathRedactedBeforeUsernameSoUserTokenInPathIsNotLeaked() {
        // homePath contains the username; replacing the path first means the username
        // inside the path is consumed by "~", and only the standalone username remains.
        let out = redactor.redact(
            "/Users/microsoft is microsoft's home",
            agentNames: [],
            homePath: "/Users/microsoft",
            username: "microsoft"
        )
        XCTAssertFalse(out.contains("/Users/microsoft"))
        XCTAssertFalse(out.lowercased().contains("microsoft"))
        XCTAssertTrue(out.hasPrefix("~ is <user>"))
    }

    // MARK: - issueTitle

    func testIssueTitleUsesFirstNonEmptyLine() {
        let report = WorkbenchBugReport(
            userText: "\n   \nButton does nothing when clicked\nmore detail",
            contextSections: []
        )
        XCTAssertEqual(report.issueTitle(), "Button does nothing when clicked")
    }

    func testIssueTitleTruncatesLongLine() {
        let long = String(repeating: "x", count: 120)
        let title = WorkbenchBugReport(userText: long, contextSections: []).issueTitle()
        XCTAssertTrue(title.hasSuffix("…"))
        // ~70 chars + the ellipsis
        XCTAssertEqual(title.count, 71)
        XCTAssertTrue(title.hasPrefix(String(repeating: "x", count: 70)))
    }

    func testIssueTitleDoesNotTruncateShortLine() {
        let title = WorkbenchBugReport(userText: "short and sweet", contextSections: []).issueTitle()
        XCTAssertEqual(title, "short and sweet")
        XCTAssertFalse(title.hasSuffix("…"))
    }

    func testIssueTitleBlankFallback() {
        XCTAssertEqual(
            WorkbenchBugReport(userText: "   \n\t\n  ", contextSections: []).issueTitle(),
            "Workbench bug report"
        )
        XCTAssertEqual(
            WorkbenchBugReport(userText: "", contextSections: []).issueTitle(),
            "Workbench bug report"
        )
    }

    // MARK: - issueBody

    func testIssueBodyRedactsUserTextAndSections() {
        let report = WorkbenchBugReport(
            userText: "I am microsoft and I saw a crash",
            contextSections: [
                WorkbenchBugReportSection(title: "PATH", body: "/Users/microsoft/bin"),
                WorkbenchBugReportSection(title: "Agent", body: "Doris crashed")
            ]
        )
        let body = report.issueBody(
            redactor: redactor,
            agentNames: ["Doris"],
            homePath: "/Users/microsoft",
            username: "microsoft"
        )
        // user text redacted
        XCTAssertTrue(body.contains("I am <user> and I saw a crash"))
        XCTAssertFalse(body.lowercased().contains("microsoft"))
        // anonymized-context header present
        XCTAssertTrue(body.contains("---\n_Auto-attached context (anonymized):_\n"))
        // section titles present, bodies redacted
        XCTAssertTrue(body.contains("**PATH:**\n~/bin"))
        XCTAssertTrue(body.contains("**Agent:**\n<agent> crashed"))
        XCTAssertFalse(body.contains("/Users/microsoft"))
        XCTAssertFalse(body.contains("Doris"))
    }

    func testIssueBodyOmitsEmptyBodySections() {
        let report = WorkbenchBugReport(
            userText: "something broke",
            contextSections: [
                WorkbenchBugReportSection(title: "Kept", body: "real content"),
                WorkbenchBugReportSection(title: "Empty", body: ""),
                WorkbenchBugReportSection(title: "Whitespace", body: "   \n  ")
            ]
        )
        let body = report.issueBody(
            redactor: redactor,
            agentNames: [],
            homePath: "",
            username: ""
        )
        XCTAssertTrue(body.contains("**Kept:**\nreal content"))
        XCTAssertFalse(body.contains("**Empty:**"))
        XCTAssertFalse(body.contains("**Whitespace:**"))
    }

    func testIssueBodyStartsWithRedactedUserText() {
        let report = WorkbenchBugReport(userText: "plain report", contextSections: [])
        let body = report.issueBody(redactor: redactor, agentNames: [], homePath: "", username: "")
        XCTAssertTrue(body.hasPrefix("plain report\n\n---\n_Auto-attached context (anonymized):_\n"))
    }

    // MARK: - Section model

    func testSectionIsCodableAndEquatable() throws {
        let section = WorkbenchBugReportSection(title: "T", body: "B")
        let data = try JSONEncoder().encode(section)
        let decoded = try JSONDecoder().decode(WorkbenchBugReportSection.self, from: data)
        XCTAssertEqual(section, decoded)
    }
}
