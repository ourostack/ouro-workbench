import XCTest
@testable import OuroWorkbenchCore

/// The shared-seam SF Symbol decision for a live agent readiness.
///
/// The agent DETAIL pane (`AgentStatusCard.statusIcon`) and the empty-state row
/// (`OuroAgentRowView.agentStatusImage`) used to pick their icon from the raw
/// config `agent.status` — so an expired-token agent (config-`.ready`, live
/// `unauthorized`) drew the SUCCESS glyph (`checkmark.seal.fill`). This seam moves
/// the icon decision off config status and onto the LIVE readiness, so the success
/// glyph is reachable ONLY from `.ready` (the sole state a `.working` live verdict
/// produces). Tested exhaustively over all nine `LiveReadiness` cases.
final class InstalledAgentRowIconTests: XCTestCase {

    private typealias R = InstalledAgentRowPresentation.LiveReadiness
    private let success = "checkmark.seal.fill"

    // MARK: - The success glyph is reachable ONLY from .ready

    func testReadyMapsToTheSuccessGlyph() {
        XCTAssertEqual(InstalledAgentRowPresentation.iconSystemName(for: .ready), success)
    }

    func testSuccessGlyphMapsFromReadyAlone() {
        // The whole point of the seam: NO state other than .ready may produce the
        // success glyph. A confirmed-bad or pending agent must never wear the seal.
        for readiness in allReadinessCases where readiness != .ready {
            XCTAssertNotEqual(
                InstalledAgentRowPresentation.iconSystemName(for: readiness),
                success,
                "\(readiness) must NOT map to the success glyph — only .ready may"
            )
        }
    }

    // MARK: - Pending states stay CALM (no warning glyph) — guard the inverse false-RED

    func testCheckingUsesACalmInProgressGlyph() {
        // A check in flight is NOT a problem — it must not show the warning glyph.
        let icon = InstalledAgentRowPresentation.iconSystemName(for: .checking)
        XCTAssertEqual(icon, "ellipsis.circle")
        XCTAssertNotEqual(icon, "exclamationmark.triangle.fill", ".checking must read calm, not alarmed")
    }

    func testUnverifiedUsesACalmQuestionGlyph() {
        // Config looks ready but unconfirmed — calm, not alarmed.
        let icon = InstalledAgentRowPresentation.iconSystemName(for: .unverified)
        XCTAssertEqual(icon, "questionmark.circle")
        XCTAssertNotEqual(icon, "exclamationmark.triangle.fill", ".unverified must read calm, not alarmed")
    }

    // MARK: - Confirmed-bad verdicts get the warning glyph

    func testAuthExpiredUsesTheWarningGlyph() {
        XCTAssertEqual(InstalledAgentRowPresentation.iconSystemName(for: .authExpired), "exclamationmark.triangle.fill")
    }

    func testVaultLockedUsesTheWarningGlyph() {
        XCTAssertEqual(InstalledAgentRowPresentation.iconSystemName(for: .vaultLocked), "exclamationmark.triangle.fill")
    }

    func testUnreachableUsesTheWarningGlyph() {
        XCTAssertEqual(InstalledAgentRowPresentation.iconSystemName(for: .unreachable), "exclamationmark.triangle.fill")
    }

    // MARK: - Config states keep their distinct glyphs

    func testDisabledUsesThePauseGlyph() {
        XCTAssertEqual(InstalledAgentRowPresentation.iconSystemName(for: .disabled), "pause.circle.fill")
    }

    func testMissingConfigUsesTheStopGlyph() {
        XCTAssertEqual(InstalledAgentRowPresentation.iconSystemName(for: .missingConfig), "xmark.octagon.fill")
    }

    func testInvalidConfigUsesTheStopGlyph() {
        XCTAssertEqual(InstalledAgentRowPresentation.iconSystemName(for: .invalidConfig), "xmark.octagon.fill")
    }

    // MARK: - Every case returns a non-empty glyph (exhaustiveness)

    func testEveryReadinessHasANonEmptyGlyph() {
        for readiness in allReadinessCases {
            XCTAssertFalse(
                InstalledAgentRowPresentation.iconSystemName(for: readiness).isEmpty,
                "\(readiness) must map to a non-empty SF Symbol"
            )
        }
    }

    /// All nine `LiveReadiness` cases. Kept local (the enum has no `CaseIterable`),
    /// so this list is the test's own exhaustiveness contract.
    private var allReadinessCases: [R] {
        [.ready, .checking, .authExpired, .vaultLocked, .unreachable, .unverified, .disabled, .missingConfig, .invalidConfig]
    }
}
