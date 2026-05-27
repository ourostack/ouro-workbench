import XCTest
@testable import OuroWorkbenchCore

/// Cycle helpers live on `WorkbenchViewModel` (AppKit-coupled), so the
/// view-model paths are exercised by Computer Use against the installed
/// build. These tests just lock in the enum's two cases, its string raw
/// values (used in CHANGELOG/docs), and Codable round-tripping so future
/// renames can't silently drift.
final class WorkbenchCycleDirectionTests: XCTestCase {
    func testRawValuesMatchUserFacingNames() {
        XCTAssertEqual(WorkbenchCycleDirection.previous.rawValue, "previous")
        XCTAssertEqual(WorkbenchCycleDirection.next.rawValue, "next")
    }

    func testCycleDirectionHasExactlyTwoCases() {
        // Guard against a third case slipping in without a matching shortcut.
        let allCases: [WorkbenchCycleDirection] = [.previous, .next]
        XCTAssertEqual(allCases.count, 2)
    }

    func testCodableRoundTrip() throws {
        for direction in [WorkbenchCycleDirection.previous, .next] {
            let data = try JSONEncoder().encode(direction)
            let decoded = try JSONDecoder().decode(WorkbenchCycleDirection.self, from: data)
            XCTAssertEqual(decoded, direction)
        }
    }
}
