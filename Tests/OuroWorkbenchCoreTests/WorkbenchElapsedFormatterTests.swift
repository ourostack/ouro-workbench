import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchElapsedFormatterTests: XCTestCase {
    private func formatted(_ secondsAgo: TimeInterval) -> String {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        return WorkbenchElapsedFormatter.coarseDescription(
            since: now.addingTimeInterval(-secondsAgo),
            now: now
        )
    }

    func testRendersSecondsWhenUnderOneMinute() {
        XCTAssertEqual(formatted(0), "0s")
        XCTAssertEqual(formatted(1), "1s")
        XCTAssertEqual(formatted(45), "45s")
        XCTAssertEqual(formatted(59), "59s")
    }

    func testRendersMinutesAfterOneMinute() {
        XCTAssertEqual(formatted(60), "1m")
        XCTAssertEqual(formatted(150), "2m")
        XCTAssertEqual(formatted(60 * 59), "59m")
    }

    func testRendersHoursWithRemainder() {
        XCTAssertEqual(formatted(60 * 60), "1h")
        XCTAssertEqual(formatted(60 * 60 + 60), "1h 1m")
        XCTAssertEqual(formatted(60 * 60 * 2 + 60 * 14), "2h 14m")
    }

    func testRendersExactHoursWithoutMinuteSuffix() {
        // 3h exactly should be "3h", not "3h 0m" — the suffix would noise
        // the pill width.
        XCTAssertEqual(formatted(60 * 60 * 3), "3h")
    }

    func testNegativeDurationsClampToZero() {
        // Should never happen in practice (start dates can't be future),
        // but the formatter clamps so a sign flip never crashes the UI.
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let future = now.addingTimeInterval(60)
        XCTAssertEqual(
            WorkbenchElapsedFormatter.coarseDescription(since: future, now: now),
            "0s"
        )
    }
}
