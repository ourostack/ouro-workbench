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

    func testFilterRequiresEveryQueryTokenToMatch() {
        let commands = [
            WorkbenchCommandDescriptor(id: .collectSupportDiagnostics, title: "Collect Support Diagnostics", detail: "Create zip", systemImage: "lifepreserver", keywords: ["diag"]),
            WorkbenchCommandDescriptor(id: .openSupportDiagnosticsFolder, title: "Open Diagnostics Folder", detail: "Reveal support output", systemImage: "folder", keywords: ["finder"])
        ]

        XCTAssertEqual(
            WorkbenchCommandPalette().filter(commands, query: "diag folder").map(\.id),
            [.openSupportDiagnosticsFolder]
        )
    }

    func testFilterMatchesCommandIDAndKeywords() {
        let commands = [
            WorkbenchCommandDescriptor(id: .sendEOFToSelectedSession, title: "Send EOF", detail: "Send Ctrl-D", systemImage: "eject", keywords: ["signal"]),
            WorkbenchCommandDescriptor(id: .refreshWorkspace, title: "Refresh Workspace", detail: "Reload status", systemImage: "arrow.clockwise", keywords: ["sync"])
        ]

        XCTAssertEqual(
            WorkbenchCommandPalette().filter(commands, query: "ctrl-d").map(\.id),
            [.sendEOFToSelectedSession]
        )
        XCTAssertEqual(
            WorkbenchCommandPalette().filter(commands, query: "refreshWorkspace").map(\.id),
            [.refreshWorkspace]
        )
    }
}
