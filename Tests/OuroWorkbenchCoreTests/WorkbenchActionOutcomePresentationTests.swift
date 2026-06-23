import XCTest
@testable import OuroWorkbenchCore

/// The boss action-log false-green fix: an in-flight optimistic ack used to log
/// `succeeded:true` and wear a GREEN check before its real outcome was known.
/// This seam resolves a three-state tone (pending / succeeded / failed) so an
/// in-flight entry renders NEUTRAL — a green check now means a VERIFIED success.
///
/// HONESTY INVARIANT (asserted exhaustively below): the green check and `.green`
/// are produced ONLY for `.succeeded`, which `tone(...)` yields ONLY when
/// `isInFlight == false && succeeded == true`. Pending dominates the meaningless-
/// while-pending `succeeded` flag, and a real failure is NEVER swallowed by pending.
final class WorkbenchActionOutcomePresentationTests: XCTestCase {
    typealias P = WorkbenchActionOutcomePresentation

    // MARK: - tone(isInFlight:succeeded:) — all four (isInFlight × succeeded) combos

    func testInFlightSucceededTrueIsPending() {
        XCTAssertEqual(P.tone(isInFlight: true, succeeded: true), .pending)
    }

    func testInFlightSucceededFalseIsPending() {
        // Pending dominates even when the (meaningless-while-pending) flag is false.
        XCTAssertEqual(P.tone(isInFlight: true, succeeded: false), .pending)
    }

    func testNotInFlightSucceededTrueIsSucceeded() {
        XCTAssertEqual(P.tone(isInFlight: false, succeeded: true), .succeeded)
    }

    func testNotInFlightSucceededFalseIsFailed() {
        XCTAssertEqual(P.tone(isInFlight: false, succeeded: false), .failed)
    }

    // MARK: - iconSystemName(for:) — every Tone arm

    func testIconForPendingIsNeutralEllipsis() {
        XCTAssertEqual(P.iconSystemName(for: .pending), "ellipsis.circle")
    }

    func testIconForSucceededIsGreenCheck() {
        XCTAssertEqual(P.iconSystemName(for: .succeeded), "checkmark.circle.fill")
    }

    func testIconForFailedIsWarningTriangle() {
        XCTAssertEqual(P.iconSystemName(for: .failed), "exclamationmark.triangle.fill")
    }

    // MARK: - color(for:) — every Tone arm

    func testColorForPendingIsNeutral() {
        XCTAssertEqual(P.color(for: .pending), .neutral)
    }

    func testColorForSucceededIsGreen() {
        XCTAssertEqual(P.color(for: .succeeded), .green)
    }

    func testColorForFailedIsOrange() {
        XCTAssertEqual(P.color(for: .failed), .orange)
    }

    // MARK: - label(for:) — every Tone arm

    func testLabelForPending() {
        XCTAssertEqual(P.label(for: .pending), "In progress")
    }

    func testLabelForSucceeded() {
        XCTAssertEqual(P.label(for: .succeeded), "Succeeded")
    }

    func testLabelForFailed() {
        XCTAssertEqual(P.label(for: .failed), "Failed")
    }

    // MARK: - Honesty invariant — green check / .green ONLY for a VERIFIED success

    func testGreenCheckOnlyForNonInFlightSuccess() {
        // Sweep every (isInFlight × succeeded) combo. The GREEN check icon and the
        // .green color may appear for EXACTLY the (false, true) combo and no other.
        for isInFlight in [true, false] {
            for succeeded in [true, false] {
                let tone = P.tone(isInFlight: isInFlight, succeeded: succeeded)
                let icon = P.iconSystemName(for: tone)
                let color = P.color(for: tone)
                let isVerifiedSuccess = (isInFlight == false && succeeded == true)

                XCTAssertEqual(
                    icon == "checkmark.circle.fill", isVerifiedSuccess,
                    "green check must appear iff verified success (isInFlight=\(isInFlight), succeeded=\(succeeded))"
                )
                XCTAssertEqual(
                    color == .green, isVerifiedSuccess,
                    ".green must appear iff verified success (isInFlight=\(isInFlight), succeeded=\(succeeded))"
                )
            }
        }
    }

    func testInFlightAlwaysPendingAndNeutralRegardlessOfFlag() {
        // An in-flight entry is ALWAYS pending/neutral — the succeeded flag can't
        // make it green.
        for succeeded in [true, false] {
            let tone = P.tone(isInFlight: true, succeeded: succeeded)
            XCTAssertEqual(tone, .pending)
            XCTAssertEqual(P.color(for: tone), .neutral)
            XCTAssertNotEqual(P.iconSystemName(for: tone), "checkmark.circle.fill")
        }
    }

    func testRealFailureIsNeverSwallowedByPending() {
        // A genuinely-failed (not in-flight) entry stays failed/orange — pending is
        // ONLY for the optimistic in-flight ack, never for a settled failure.
        let tone = P.tone(isInFlight: false, succeeded: false)
        XCTAssertEqual(tone, .failed)
        XCTAssertEqual(P.color(for: tone), .orange)
        XCTAssertEqual(P.iconSystemName(for: tone), "exclamationmark.triangle.fill")
    }
}
