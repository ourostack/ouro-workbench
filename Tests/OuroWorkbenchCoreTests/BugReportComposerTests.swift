import XCTest
@testable import OuroWorkbenchCore

final class BugReportComposerTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        comps.hour = h; comps.minute = mi; comps.second = s
        comps.timeZone = utc
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: comps)!
    }

    private func content(
        note: String = "Terminal froze",
        sessions: [BugReportSession] = [],
        decisions: [BossInboxDecision] = [],
        actions: [WorkbenchActionLogEntry] = [],
        attachments: [String] = ["screenshot.png", "diagnostics.zip"],
        warnings: [String] = []
    ) -> BugReportContent {
        BugReportContent(
            note: note,
            appName: "Ouro Workbench",
            appVersion: "0.1.105",
            buildHash: "abc1234",
            osVersion: "macOS 15.2",
            generatedAt: date(2026, 5, 28, 14, 3, 22),
            bossName: "slugger",
            bossWatchEnabled: true,
            autoAdvanceEnabled: false,
            sessions: sessions,
            recentDecisions: decisions,
            recentActions: actions,
            attachmentNames: attachments,
            collectionWarnings: warnings
        )
    }

    // MARK: - slug

    func testSlugLowercasesAndHyphenates() {
        XCTAssertEqual(BugReportComposer.slug(from: "Terminal Rendering Glitch!"), "terminal-rendering-glitch")
    }

    func testSlugCollapsesRunsAndTrimsEdges() {
        XCTAssertEqual(BugReportComposer.slug(from: "  --Hello,, World!!  "), "hello-world")
    }

    func testSlugIsEmptyForNoUsableCharacters() {
        XCTAssertEqual(BugReportComposer.slug(from: "—!!! …"), "")
    }

    func testSlugRespectsMaxLengthWithoutTrailingHyphen() {
        let slug = BugReportComposer.slug(from: String(repeating: "ab ", count: 40), maxLength: 10)
        XCTAssertLessThanOrEqual(slug.count, 10)
        XCTAssertFalse(slug.hasSuffix("-"))
    }

    // MARK: - directoryName

    func testDirectoryNameIsSortableTimestampPlusSlug() {
        let name = BugReportComposer.directoryName(
            date: date(2026, 5, 28, 14, 3, 22),
            note: "Terminal froze",
            timeZone: utc
        )
        XCTAssertEqual(name, "20260528-140322-terminal-froze")
    }

    func testDirectoryNameFallsBackToTimestampWhenNoteHasNoSlug() {
        let name = BugReportComposer.directoryName(
            date: date(2026, 5, 28, 14, 3, 22),
            note: "!!!",
            timeZone: utc
        )
        XCTAssertEqual(name, "20260528-140322")
    }

    // MARK: - markdown

    func testMarkdownHeaderCarriesVersionOsAndBossPosture() {
        let md = BugReportComposer.markdown(content())
        XCTAssertTrue(md.contains("# Ouro Workbench bug report"))
        XCTAssertTrue(md.contains("0.1.105 (build abc1234)"))
        XCTAssertTrue(md.contains("**macOS:** macOS 15.2"))
        XCTAssertTrue(md.contains("Boss Watch on · Auto-advance off"))
    }

    func testMarkdownRendersNoteOrPlaceholder() {
        XCTAssertTrue(BugReportComposer.markdown(content(note: "Terminal froze")).contains("Terminal froze"))
        XCTAssertTrue(BugReportComposer.markdown(content(note: "   ")).contains("_(no description provided)_"))
    }

    func testMarkdownListsAttachmentsOrNone() {
        XCTAssertTrue(BugReportComposer.markdown(content()).contains("- `screenshot.png`"))
        XCTAssertTrue(BugReportComposer.markdown(content(attachments: [])).contains("## Attachments\n\n_(none)_"))
    }

    func testMarkdownRendersSessionTableWithEscapedCells() {
        let session = BugReportSession(
            name: "build | weird",
            status: "running",
            attention: "waitingOnHuman",
            trust: "trusted",
            friend: "Ari",
            workingDirectory: "/tmp/proj",
            gitBranch: "main"
        )
        let md = BugReportComposer.markdown(content(sessions: [session]))
        XCTAssertTrue(md.contains("## Sessions (1)"))
        XCTAssertTrue(md.contains("| Session | Status | Attention | Trust | Friend | Branch | Directory |"))
        // The pipe inside the name must be escaped so it doesn't split the row.
        XCTAssertTrue(md.contains("build \\| weird"))
        XCTAssertTrue(md.contains("waitingOnHuman"))
    }

    func testMarkdownRendersDecisionWithWhyAndCollapsesNewlines() {
        let decision = BossInboxDecision(
            occurredAt: date(2026, 5, 28, 13, 0, 0),
            source: "boss:slugger",
            sessionName: "api",
            friendName: "Ari",
            prompt: "Run tests?\n(y/N)",
            kind: .autoAdvance,
            proposedInput: "y",
            preferenceCited: "Ari always runs tests",
            confidence: 0.92,
            reasoning: "Safe, reversible",
            status: .applied
        )
        let md = BugReportComposer.markdown(content(decisions: [decision]))
        XCTAssertTrue(md.contains("## Recent boss decisions (1)"))
        XCTAssertTrue(md.contains("`autoAdvance` (applied)"))
        XCTAssertTrue(md.contains("sent `y`"))
        XCTAssertTrue(md.contains("prompt: Run tests? (y/N)"))
        XCTAssertTrue(md.contains("why: Ari always runs tests"))
        XCTAssertTrue(md.contains("confidence: 0.92"))
    }

    func testMarkdownTruncatesLongDecisionAndActionLists() {
        let decisions = (0..<(BugReportComposer.decisionLimit + 5)).map { i in
            BossInboxDecision(source: "boss", prompt: "p\(i)", kind: .escalate, reasoning: "")
        }
        let actions = (0..<(BugReportComposer.actionLimit + 7)).map { i in
            WorkbenchActionLogEntry(source: "native", action: "a\(i)", result: "ok", succeeded: true)
        }
        let md = BugReportComposer.markdown(content(decisions: decisions, actions: actions))
        XCTAssertTrue(md.contains("…and 5 older"))
        XCTAssertTrue(md.contains("…and 7 older"))
    }

    func testMarkdownEscapesPipeInActionResult() {
        let action = WorkbenchActionLogEntry(
            source: "native",
            action: "collectSupportDiagnostics",
            result: "wrote a|b.zip",
            succeeded: false
        )
        let md = BugReportComposer.markdown(content(actions: [action]))
        XCTAssertTrue(md.contains("wrote a\\|b.zip"))
        XCTAssertTrue(md.contains("✗"))
    }

    func testMarkdownIncludesCollectionWarnings() {
        let md = BugReportComposer.markdown(content(warnings: ["Screenshot capture failed"]))
        XCTAssertTrue(md.contains("## Collection warnings"))
        XCTAssertTrue(md.contains("- Screenshot capture failed"))
    }

    func testMarkdownEndsWithTrailingNewline() {
        XCTAssertTrue(BugReportComposer.markdown(content()).hasSuffix("\n"))
    }
}
