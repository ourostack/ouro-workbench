import XCTest
@testable import OuroWorkbenchCore

/// U23(b): a dashboard metric chip that can't report yet must say so plainly —
/// not a bare "?" that reads identical to a real value (and identical to a
/// genuine zero). This pure resolver turns "(value, isAvailable, reason)" into a
/// presentation that distinguishes a real number, a genuine zero, and an
/// unavailable probe (a muted dash + a specific reason + a retry affordance).
final class MetricValuePresentationTests: XCTestCase {

    func testAvailableValueRendersTheNumber() {
        let p = MetricValuePresentation.resolve(value: 3, isAvailable: true, issue: nil)
        XCTAssertEqual(p.text, "3")
        XCTAssertFalse(p.isUnavailable)
        XCTAssertFalse(p.canRetry)
    }

    func testGenuineZeroIsAValueNotUnavailable() {
        let p = MetricValuePresentation.resolve(value: 0, isAvailable: true, issue: nil)
        XCTAssertEqual(p.text, "0")
        XCTAssertFalse(p.isUnavailable, "a real zero is a value, visually distinct from unavailable")
    }

    func testUnavailableRendersDashNotQuestionMark() {
        let p = MetricValuePresentation.resolve(value: nil, isAvailable: false, issue: nil)
        XCTAssertEqual(p.text, "—")
        XCTAssertTrue(p.isUnavailable)
        XCTAssertNotEqual(p.text, "?")
    }

    func testUnavailableExposesItsSpecificReason() {
        let p = MetricValuePresentation.resolve(
            value: nil,
            isAvailable: false,
            issue: "needs-me: the needs-me probe timed out"
        )
        // The reason is on the presentation, not hover-only guessing.
        XCTAssertEqual(p.reason, "needs-me: the needs-me probe timed out")
    }

    func testUnavailableWithoutAnIssueStillReadsAsNotAValue() {
        let p = MetricValuePresentation.resolve(value: nil, isAvailable: false, issue: nil)
        XCTAssertTrue(p.isUnavailable)
        XCTAssertEqual(p.reason, "This metric can't report right now.")
    }

    func testUnavailableOffersRetry() {
        let p = MetricValuePresentation.resolve(value: nil, isAvailable: false, issue: nil)
        XCTAssertTrue(p.canRetry, "an unavailable probe offers a one-click retry")
    }

    func testAvailableDoesNotOfferRetry() {
        XCTAssertFalse(MetricValuePresentation.resolve(value: 5, isAvailable: true, issue: nil).canRetry)
    }

    func testValueMissingButMarkedAvailableFallsBackToDashNotCrash() {
        // Defensive: availability says ok but the count is nil — treat as a real
        // zero-less unknown, render the dash rather than force-unwrap.
        let p = MetricValuePresentation.resolve(value: nil, isAvailable: true, issue: nil)
        XCTAssertEqual(p.text, "—")
        XCTAssertTrue(p.isUnavailable)
    }

    // The string-availability convenience used by chips whose count is itself a
    // string (e.g. claims "ok"/"unknown") keeps the same not-a-value contract.
    func testStringConvenienceUnavailableRendersDash() {
        let p = MetricValuePresentation.resolve(text: "unknown", isAvailable: false, issue: nil)
        XCTAssertEqual(p.text, "—")
        XCTAssertTrue(p.isUnavailable)
    }

    func testStringConvenienceAvailableKeepsText() {
        let p = MetricValuePresentation.resolve(text: "ok", isAvailable: true, issue: nil)
        XCTAssertEqual(p.text, "ok")
        XCTAssertFalse(p.isUnavailable)
    }
}
