import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchCommandPaletteTests: XCTestCase {
    func testEmptyQueryReturnsCommandsInOriginalOrder() {
        let commands = [
            WorkbenchCommandDescriptor(id: .newSession, title: "New Session", detail: "Create", systemImage: "plus"),
            WorkbenchCommandDescriptor(id: .bossCheckIn, title: "Check In", detail: "Ask boss", systemImage: "bubble")
        ]

        XCTAssertEqual(WorkbenchCommandPalette().filter(commands, query: " "), commands)
    }

    func testFilterMatchesTitleAndDetailCaseInsensitively() {
        let commands = [
            WorkbenchCommandDescriptor(id: .newSession, title: "New Session", detail: "Create", systemImage: "plus"),
            WorkbenchCommandDescriptor(id: .searchTranscripts, title: "Search Transcripts", detail: "Find history", systemImage: "magnifyingglass")
        ]

        XCTAssertEqual(
            WorkbenchCommandPalette().filter(commands, query: "history").map(\.id),
            [.searchTranscripts]
        )
        XCTAssertEqual(
            WorkbenchCommandPalette().filter(commands, query: "new").map(\.id),
            [.newSession]
        )
    }

    func testFilterMatchesDiacriticsInsensitively() {
        let commands = [
            WorkbenchCommandDescriptor(id: .searchTranscripts, title: "Café Transcript", detail: "Find history", systemImage: "magnifyingglass")
        ]

        XCTAssertEqual(
            WorkbenchCommandPalette().filter(commands, query: "cafe").map(\.id),
            [.searchTranscripts]
        )
    }
}
