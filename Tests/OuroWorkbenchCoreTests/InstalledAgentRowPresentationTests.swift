import XCTest
@testable import OuroWorkbenchCore

/// U36: the empty-state "Installed agents" card used to color every non-ready
/// agent with ONE wordless orange dot, collapsing three distinct states (disabled
/// / agent.json missing / invalid config) into an alarm the operator couldn't read
/// or resolve. This pure seam gives each status a 3-way dot color (matching the
/// sidebar row) AND a human-readable reason, so an intentionally-disabled agent
/// doesn't read as an unexplained error.
final class InstalledAgentRowPresentationTests: XCTestCase {

    // MARK: - 3-way dot color (matches SidebarAgentRow)

    func testReadyIsGreen() {
        XCTAssertEqual(InstalledAgentRowPresentation.dotColor(for: .ready), .green)
    }

    func testDisabledAndMissingConfigAreOrange() {
        XCTAssertEqual(InstalledAgentRowPresentation.dotColor(for: .disabled), .orange)
        XCTAssertEqual(InstalledAgentRowPresentation.dotColor(for: .missingConfig), .orange)
    }

    func testInvalidConfigIsRed() {
        // An invalid config is a genuine error, distinct from a deliberate disable
        // or a not-yet-configured agent — it gets the loud red dot, not orange.
        XCTAssertEqual(InstalledAgentRowPresentation.dotColor(for: .invalidConfig), .red)
    }

    // MARK: - Human-readable reason for non-ready rows

    func testReadyHasNoReason() {
        // A ready agent needs no explanation — the row reads as available.
        XCTAssertNil(InstalledAgentRowPresentation.reason(for: .ready, detail: "ready"))
    }

    func testDisabledReadsAsDisabled() {
        let reason = InstalledAgentRowPresentation.reason(for: .disabled, detail: "disabled in agent.json")
        XCTAssertEqual(reason, "Disabled in agent.json")
    }

    func testMissingConfigReadsAsMissingAgentJson() {
        let reason = InstalledAgentRowPresentation.reason(for: .missingConfig, detail: "agent.json missing")
        XCTAssertEqual(reason, "No agent.json — this bundle isn't configured yet")
    }

    func testInvalidConfigReadsAsInvalidAndCarriesTheDetail() {
        // The invalid-config reason names the problem in plain words; the scanner's
        // raw error detail rides along so the operator can see what's wrong.
        let reason = InstalledAgentRowPresentation.reason(
            for: .invalidConfig,
            detail: "The data couldn’t be read because it isn’t in the correct format."
        )
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().hasPrefix("invalid agent.json"), "got: \(reason!)")
        XCTAssertTrue(reason!.contains("isn’t in the correct format"), "carries the raw detail; got: \(reason!)")
    }

    func testInvalidConfigWithEmptyDetailStillReadsAsInvalid() {
        let reason = InstalledAgentRowPresentation.reason(for: .invalidConfig, detail: "")
        XCTAssertEqual(reason, "Invalid agent.json")
    }
}
