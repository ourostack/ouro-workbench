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

    // MARK: - Golden markdown structure (mutation-testing pilot)
    //
    // The composer's docstring promises the document is "built by a pure function
    // the tests can pin byte-for-byte" — but the existing tests only asserted
    // `contains(...)` substrings, so the whole skeleton (blank-line spacers,
    // section headers, table header/separator rows, placeholders, and several
    // session/decision fields) was rendered but never pinned: dropping any of
    // them survived. This asserts the FULL document against a golden string,
    // with only the two machine-timezone-dependent `timestamp()` outputs
    // normalised to `<TS>` (that formatter sets no timezone, so its absolute
    // value isn't portable — its FORMAT is pinned separately below).

    /// Replace the volatile `yyyy-MM-dd HH:mm:ss` timestamps with `<TS>` so the
    /// rest of the document can be pinned byte-for-byte regardless of CI timezone.
    private func normalizingTimestamps(_ text: String) -> String {
        let pattern = #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#
        return text.replacingOccurrences(of: pattern, with: "<TS>", options: .regularExpression)
    }

    func testMarkdownMatchesGoldenStructureByteForByte() {
        let session = BugReportSession(
            name: "Claude", status: "running", attention: "ok", trust: "trusted",
            friend: "buddy", workingDirectory: "/repo/x", gitBranch: "main"
        )
        let decision = BossInboxDecision(
            occurredAt: date(2026, 5, 28, 13, 0, 0),
            source: "boss:slugger", sessionName: "Claude",
            prompt: "do thing", kind: .escalate, reasoning: "because"
        )
        let action = WorkbenchActionLogEntry(
            occurredAt: date(2026, 5, 28, 13, 0, 0),
            source: "boss", action: "sendInput", result: "ok", succeeded: true
        )
        let md = BugReportComposer.markdown(
            content(sessions: [session], decisions: [decision], actions: [action], attachments: ["screenshot.png"])
        )
        let expected = """
        # Ouro Workbench bug report

        - **When:** <TS>
        - **App:** Ouro Workbench 0.1.105 (build abc1234)
        - **macOS:** macOS 15.2
        - **Boss:** slugger · Boss Watch on · Auto-advance off

        ## What happened

        Terminal froze

        ## Attachments

        - `screenshot.png`

        ## Sessions (1)

        | Session | Status | Attention | Trust | Friend | Branch | Directory |
        |---|---|---|---|---|---|---|
        | Claude | running | ok | trusted | buddy | main | /repo/x |

        ## Recent boss decisions (1)

        - **<TS>** · Claude · `escalate` (recorded)
          - prompt: do thing
          - reasoning: because

        ## Recent actions (1)

        | When | Source | Action | Target | Result | OK |
        |---|---|---|---|---|---|
        | <TS> | boss | sendInput | — | ok | ✓ |


        """
        XCTAssertEqual(normalizingTimestamps(md), expected)
    }

    /// The empty-state skeleton (no sessions / no decisions / no actions) is also
    /// pinned — its placeholders and spacing were unasserted.
    func testMarkdownMatchesGoldenStructureForEmptyCollections() {
        let md = BugReportComposer.markdown(content(note: "   ", attachments: []))
        let expected = """
        # Ouro Workbench bug report

        - **When:** <TS>
        - **App:** Ouro Workbench 0.1.105 (build abc1234)
        - **macOS:** macOS 15.2
        - **Boss:** slugger · Boss Watch on · Auto-advance off

        ## What happened

        _(no description provided)_

        ## Attachments

        _(none)_

        ## Sessions (0)

        _(no sessions)_

        ## Recent boss decisions (0)

        _(none)_

        ## Recent actions (0)

        _(none)_


        """
        XCTAssertEqual(normalizingTimestamps(md), expected)
    }

    /// Pins the `timestamp()` FORMAT (the golden tests above normalise its value).
    /// Kills the `formatter.dateFormat = "..."` / `formatter.locale = ...` drops:
    /// the When-line must read `yyyy-MM-dd HH:mm:ss` (zero-padded, 24h, no AM/PM).
    func testMarkdownTimestampUsesFixedNumericFormat() {
        let md = BugReportComposer.markdown(content())
        let pattern = #"- \*\*When:\*\* \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\n"#
        XCTAssertNotNil(
            md.range(of: pattern, options: .regularExpression),
            "the When line must use the fixed yyyy-MM-dd HH:mm:ss numeric format"
        )
    }

    // MARK: - Truncation limits & boundaries (mutation-testing pilot)

    /// Pins the limit CONSTANTS absolutely. The existing truncation test built
    /// `decisionLimit + 5` items and asserted "…and 5 older" — invariant to the
    /// constant's value (the input shifts with it), so `20→21` / `30→31` survived.
    func testTruncationLimitsAreFixedAtTheirDocumentedValues() {
        XCTAssertEqual(BugReportComposer.decisionLimit, 20)
        XCTAssertEqual(BugReportComposer.actionLimit, 30)
    }

    /// Exact-boundary truncation: with EXACTLY `decisionLimit` decisions there is
    /// no "…older" line; with one MORE there is "…and 1 older". The existing test
    /// only crossed the boundary by +5, so `count > limit → >=` survived.
    func testDecisionTruncationBoundaryIsExact() {
        let exactly = (0..<BugReportComposer.decisionLimit).map {
            BossInboxDecision(source: "boss", prompt: "p\($0)", kind: .escalate, reasoning: "")
        }
        let mdExact = BugReportComposer.markdown(content(decisions: exactly))
        XCTAssertFalse(mdExact.contains("older"), "exactly the limit shows no truncation note")

        let oneOver = exactly + [BossInboxDecision(source: "boss", prompt: "extra", kind: .escalate, reasoning: "")]
        let mdOver = BugReportComposer.markdown(content(decisions: oneOver))
        XCTAssertTrue(mdOver.contains("…and 1 older"), "one over the limit truncates exactly one")
    }

    /// Exact-boundary truncation for actions (companion to the decision case).
    func testActionTruncationBoundaryIsExact() {
        let exactly = (0..<BugReportComposer.actionLimit).map {
            WorkbenchActionLogEntry(source: "n", action: "a\($0)", result: "ok", succeeded: true)
        }
        XCTAssertFalse(BugReportComposer.markdown(content(actions: exactly)).contains("older"))

        let oneOver = exactly + [WorkbenchActionLogEntry(source: "n", action: "extra", result: "ok", succeeded: true)]
        XCTAssertTrue(BugReportComposer.markdown(content(actions: oneOver)).contains("…and 1 older"))
    }

    /// The slug's DEFAULT `maxLength` (40) is exercised by the directory path —
    /// the existing slug test always passed an explicit `maxLength: 10`, so the
    /// default value (and its `>=`-vs-`>` boundary at 40) was unasserted.
    func testSlugDefaultMaxLengthIsFortyAtTheBoundary() {
        // A single 50-char alphanumeric run (no hyphens to trim) is capped to
        // exactly 40 under the default; a `40→41` mutation would yield 41.
        let note = String(repeating: "a", count: 50)
        XCTAssertEqual(BugReportComposer.slug(from: note).count, 40, "the default slug cap is 40 characters")
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

    func testMarkdownRendersEmptySessionFacetsAsDashes() {
        let session = BugReportSession(name: "plain", status: "idle", attention: "none", trust: "untrusted")
        let md = BugReportComposer.markdown(content(sessions: [session]))
        XCTAssertTrue(md.contains("| plain | idle | none | untrusted | — | — | — |"))
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

    func testMarkdownClampsLongInlineWarningAndIgnoresWhitespaceOptionalFields() {
        let warning = String(repeating: "word ", count: 80)
        let decision = BossInboxDecision(
            source: "boss",
            sessionName: "api",
            friendName: "   ",
            prompt: "p",
            kind: .escalate,
            proposedInput: "   ",
            preferenceCited: "   ",
            reasoning: "   "
        )
        let md = BugReportComposer.markdown(content(decisions: [decision], warnings: [warning]))
        XCTAssertTrue(md.contains("word word"))
        XCTAssertTrue(md.contains("…"))
        XCTAssertFalse(md.contains("  - friend:"))
        XCTAssertFalse(md.contains("sent `"))
        XCTAssertFalse(md.contains("  - reasoning:"))
    }

    func testMarkdownEndsWithTrailingNewline() {
        XCTAssertTrue(BugReportComposer.markdown(content()).hasSuffix("\n"))
    }
}
