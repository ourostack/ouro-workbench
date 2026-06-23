import XCTest
@testable import OuroWorkbenchCore

/// The pure presentation seam for the MCP-registration pill. The honesty invariant under
/// test: GREEN (`.verified`) is reachable ONLY when the registration status is `.registered`
/// AND a live injection probe CONFIRMED the `workbench_*` tools are PRESENT
/// (`.confirmed(.present)`). A registered-but-unverified pill (nil / `.unconfirmed` /
/// confirmed-`.absent` verdict) must read NEUTRAL — registered in config, runtime injection
/// not yet confirmed — never a false green, and (the #262 inverse-bug watch) never a hard
/// red/error either: "unverified" ≠ "broken".
final class BossMCPPillPresentationTests: XCTestCase {

    /// Every registration status × every injection verdict (including nil). The ONLY
    /// `.verified` cell is `.registered` + `.confirmed(.present)`.
    private static let allStatuses: [BossWorkbenchMCPRegistrationStatus] = [
        .registered, .notRegistered, .needsUpdate,
        .agentMissing, .executableMissing, .invalidConfig, .toolsNotInjected,
    ]

    private static let allInjections: [WorkbenchToolsInjectionProbeOutcome?] = [
        nil,
        .unconfirmed,
        .confirmed(.present),
        .confirmed(.absent),
    ]

    // MARK: - The honesty invariant: green only from registered + confirmed-present

    func testVerifiedGreenReachableOnlyFromRegisteredAndConfirmedPresent() {
        for status in Self.allStatuses {
            for injection in Self.allInjections {
                let tone = BossMCPPillPresentation.tone(status: status, injection: injection)
                let isVerified = (tone == .verified)
                let isTheOneGreenCell = (status == .registered && injection == .confirmed(.present))
                XCTAssertEqual(
                    isVerified, isTheOneGreenCell,
                    "tone(.verified) must be reachable ONLY from .registered + .confirmed(.present); "
                        + "got \(tone) for status=\(status) injection=\(String(describing: injection))"
                )
            }
        }
    }

    func testGreenColorReachableOnlyFromTheOneVerifiedCell() {
        for status in Self.allStatuses {
            for injection in Self.allInjections {
                let tone = BossMCPPillPresentation.tone(status: status, injection: injection)
                let isGreen = (BossMCPPillPresentation.color(for: tone) == .green)
                let isTheOneGreenCell = (status == .registered && injection == .confirmed(.present))
                XCTAssertEqual(
                    isGreen, isTheOneGreenCell,
                    "green is reachable ONLY from the verified cell; got green=\(isGreen) "
                        + "for status=\(status) injection=\(String(describing: injection))"
                )
            }
        }
    }

    // MARK: - Registered + (not-confirmed-present) → unverified NEUTRAL (never green, never red)

    func testRegisteredButUnverifiedReadsNeutralNotGreenNotRed() {
        for injection in [nil, .unconfirmed, WorkbenchToolsInjectionProbeOutcome.confirmed(.absent)] {
            let tone = BossMCPPillPresentation.tone(status: .registered, injection: injection)
            // `.confirmed(.absent)` against a still-`.registered` snapshot (the overlay hadn't
            // flipped it to `.toolsNotInjected` yet) is unverified, not green.
            XCTAssertEqual(
                tone, .unverified,
                "registered + non-confirmed-present must be .unverified; got \(tone) "
                    + "for injection=\(String(describing: injection))"
            )
            let color = BossMCPPillPresentation.color(for: tone)
            XCTAssertEqual(color, .neutral, "unverified must read NEUTRAL, not green/orange/red")
            XCTAssertNotEqual(color, .green, "unverified must NEVER read green")
            XCTAssertNotEqual(color, .red, "unverified must NEVER read red (the #262 inverse-bug watch)")
        }
    }

    // MARK: - Status-driven tones (injection ignored for non-registered)

    func testToolsNotInjectedIsOrangeNeedsAttentionRegardlessOfInjection() {
        for injection in Self.allInjections {
            let tone = BossMCPPillPresentation.tone(status: .toolsNotInjected, injection: injection)
            XCTAssertEqual(tone, .notInjected, "tools-not-injected is its own tone")
            XCTAssertEqual(BossMCPPillPresentation.color(for: tone), .orange)
        }
    }

    func testNeedsUpdateIsNeedsAttentionOrange() {
        let tone = BossMCPPillPresentation.tone(status: .needsUpdate, injection: nil)
        XCTAssertEqual(tone, .needsAttention)
        XCTAssertEqual(BossMCPPillPresentation.color(for: tone), .orange)
    }

    func testNotRegisteredIsNotRegisteredOrange() {
        let tone = BossMCPPillPresentation.tone(status: .notRegistered, injection: nil)
        XCTAssertEqual(tone, .notRegistered)
        XCTAssertEqual(BossMCPPillPresentation.color(for: tone), .orange)
    }

    func testStructuralFailuresAreErrorRed() {
        for status: BossWorkbenchMCPRegistrationStatus in [.agentMissing, .executableMissing, .invalidConfig] {
            let tone = BossMCPPillPresentation.tone(status: status, injection: nil)
            XCTAssertEqual(tone, .error, "structural failure \(status) is the .error tone")
            XCTAssertEqual(BossMCPPillPresentation.color(for: tone), .red)
        }
    }

    // MARK: - Labels (every tone non-empty; verified/unverified distinct)

    func testLabelsAreDistinctAndNonEmptyForEveryTone() {
        let tones: [BossMCPPillPresentation.Tone] = [
            .verified, .unverified, .notInjected, .needsAttention, .notRegistered, .error,
        ]
        var seen = Set<String>()
        for tone in tones {
            let label = BossMCPPillPresentation.label(for: tone)
            XCTAssertFalse(label.isEmpty, "label for \(tone) must be non-empty")
            XCTAssertTrue(seen.insert(label).inserted, "label for \(tone) must be distinct: \(label)")
        }
    }

    func testVerifiedAndUnverifiedLabelsAreNotEqual() {
        XCTAssertNotEqual(
            BossMCPPillPresentation.label(for: .verified),
            BossMCPPillPresentation.label(for: .unverified),
            "the unverified label must be visibly distinct from the verified one"
        )
    }

    // MARK: - color(for:) covers every tone → every SemanticColor

    func testColorForEveryToneCoversEverySemanticColor() {
        XCTAssertEqual(BossMCPPillPresentation.color(for: .verified), .green)
        XCTAssertEqual(BossMCPPillPresentation.color(for: .unverified), .neutral)
        XCTAssertEqual(BossMCPPillPresentation.color(for: .notInjected), .orange)
        XCTAssertEqual(BossMCPPillPresentation.color(for: .needsAttention), .orange)
        XCTAssertEqual(BossMCPPillPresentation.color(for: .notRegistered), .orange)
        XCTAssertEqual(BossMCPPillPresentation.color(for: .error), .red)
    }
}
