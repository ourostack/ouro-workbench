import XCTest
@testable import OuroWorkbenchCore

/// The calm-vs-loud decision for the first-run header lives in Core so the rule — a brand-new
/// first run (no boss chosen yet) is EXPECTED and must read CALM, while a boss that IS named but
/// broken stays LOUD — is pinned by tests rather than buried in SwiftUI view literals. The
/// `BossSelectorView` / `AutonomyStatusButton` header views render this verbatim.
final class HeaderCalmPresentationTests: XCTestCase {
    // MARK: No boss chosen yet → calm

    func testEmptyBossIsCalm() {
        // Brand-new first run: no boss name, no resolved record. autonomy is .blocked under the
        // hood (no boss ⇒ readiness blocker) but the header must NOT shout it.
        let presentation = HeaderCalmPresentation.resolve(
            bossAgentName: "",
            bossAgentStatus: nil,
            autonomyState: .blocked
        )

        XCTAssertEqual(presentation.bossLabelText, "No boss yet")
        XCTAssertEqual(presentation.bossDotColor, .neutral)
        XCTAssertFalse(presentation.bossShowsMissingPill)
        XCTAssertEqual(
            presentation.bossHelp,
            "No boss set yet — pick one to let an Ouro agent watch this Mac and keep work moving."
        )
        XCTAssertEqual(presentation.ttfaText, "TTFA · off")
        XCTAssertEqual(presentation.ttfaStyle, .neutral)
        XCTAssertEqual(
            presentation.ttfaHelp,
            "Set up a boss to enable hands-off operation."
        )
    }

    func testWhitespaceOnlyBossNameIsTreatedAsEmpty() {
        let presentation = HeaderCalmPresentation.resolve(
            bossAgentName: "   \n\t ",
            bossAgentStatus: nil,
            autonomyState: .blocked
        )

        XCTAssertEqual(presentation.bossLabelText, "No boss yet")
        XCTAssertEqual(presentation.bossDotColor, .neutral)
        XCTAssertFalse(presentation.bossShowsMissingPill)
        XCTAssertEqual(presentation.ttfaText, "TTFA · off")
        XCTAssertEqual(presentation.ttfaStyle, .neutral)
    }

    // MARK: Named but not installed → loud (a real problem)

    func testNamedButMissingAgentIsLoud() {
        let presentation = HeaderCalmPresentation.resolve(
            bossAgentName: "Atlas",
            bossAgentStatus: nil,
            autonomyState: .blocked
        )

        XCTAssertEqual(presentation.bossLabelText, "Boss: Atlas")
        XCTAssertEqual(presentation.bossDotColor, .red)
        XCTAssertTrue(presentation.bossShowsMissingPill)
        XCTAssertEqual(
            presentation.bossHelp,
            "Atlas is the selected boss but isn't installed on this machine. "
                + "Pick an installed agent or create one."
        )
        // A real boss is named, so the TTFA pill reflects the actual readiness state, loudly.
        XCTAssertEqual(presentation.ttfaText, "TTFA · blocked")
        XCTAssertEqual(presentation.ttfaStyle, .real)
        XCTAssertEqual(
            presentation.ttfaHelp,
            "Human-free operation is blocked. Click to open the autonomy readiness checklist."
        )
    }

    // MARK: Named + installed states keep today's colors

    func testNamedAndReadyIsGreenWithRealTtfa() {
        let presentation = HeaderCalmPresentation.resolve(
            bossAgentName: "Atlas",
            bossAgentStatus: .ready,
            autonomyState: .ready
        )

        XCTAssertEqual(presentation.bossLabelText, "Boss: Atlas")
        XCTAssertEqual(presentation.bossDotColor, .green)
        XCTAssertFalse(presentation.bossShowsMissingPill)
        XCTAssertEqual(presentation.ttfaText, "TTFA · ready")
        XCTAssertEqual(presentation.ttfaStyle, .real)
    }

    func testNamedAndDisabledIsOrange() {
        let presentation = HeaderCalmPresentation.resolve(
            bossAgentName: "Atlas",
            bossAgentStatus: .disabled,
            autonomyState: .attention
        )

        XCTAssertEqual(presentation.bossDotColor, .orange)
        XCTAssertFalse(presentation.bossShowsMissingPill)
        XCTAssertEqual(presentation.ttfaText, "TTFA · watch")
        XCTAssertEqual(presentation.ttfaStyle, .real)
    }

    func testNamedAndMissingConfigIsOrange() {
        let presentation = HeaderCalmPresentation.resolve(
            bossAgentName: "Atlas",
            bossAgentStatus: .missingConfig,
            autonomyState: .attention
        )

        XCTAssertEqual(presentation.bossDotColor, .orange)
        XCTAssertFalse(presentation.bossShowsMissingPill)
    }

    func testNamedAndInvalidConfigIsRed() {
        let presentation = HeaderCalmPresentation.resolve(
            bossAgentName: "Atlas",
            bossAgentStatus: .invalidConfig,
            autonomyState: .blocked
        )

        XCTAssertEqual(presentation.bossDotColor, .red)
        // An installed-but-broken bundle is not "missing" — no missing pill, but loud red.
        XCTAssertFalse(presentation.bossShowsMissingPill)
        XCTAssertEqual(presentation.ttfaText, "TTFA · blocked")
        XCTAssertEqual(presentation.ttfaStyle, .real)
    }

    // MARK: bossHelp for an installed boss echoes the record detail

    func testNamedAndInstalledHelpUsesRecordDetail() {
        let presentation = HeaderCalmPresentation.resolve(
            bossAgentName: "Atlas",
            bossAgentStatus: .ready,
            autonomyState: .ready,
            installedBossHelp: "Atlas: Ready to be your boss."
        )

        XCTAssertEqual(presentation.bossHelp, "Atlas: Ready to be your boss.")
    }
}
