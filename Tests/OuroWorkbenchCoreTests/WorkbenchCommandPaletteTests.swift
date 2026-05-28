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

    func testDescriptorPayloadRoundTripsThroughCoding() throws {
        let original = WorkbenchCommandDescriptor(
            id: .selectAgent,
            title: "Select Agent: slugger",
            detail: "ready",
            systemImage: "person.crop.circle",
            keywords: ["agent", "slugger"],
            payload: "slugger"
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkbenchCommandDescriptor.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.payload, "slugger")
    }

    func testDescriptorDecodesWithoutPayloadForBackwardsCompatibility() throws {
        // Older persisted descriptors had no payload field; decoding should
        // succeed and yield a nil payload rather than throwing.
        let legacyJSON = """
        {
            "id": "refreshWorkspace",
            "title": "Refresh Workspace",
            "detail": "Reload status",
            "systemImage": "arrow.clockwise",
            "keywords": ["sync"]
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WorkbenchCommandDescriptor.self, from: legacyJSON)
        XCTAssertEqual(decoded.id, .refreshWorkspace)
        XCTAssertNil(decoded.payload)
    }

    func testFilterMatchesPayloadKeyword() {
        let commands = [
            WorkbenchCommandDescriptor(
                id: .selectAgent,
                title: "Select Agent: slugger",
                detail: "ready",
                systemImage: "person.crop.circle",
                keywords: ["agent", "switch", "slugger"],
                payload: "slugger"
            ),
            WorkbenchCommandDescriptor(
                id: .selectAgent,
                title: "Select Agent: caretaker",
                detail: "ready",
                systemImage: "person.crop.circle",
                keywords: ["agent", "switch", "caretaker"],
                payload: "caretaker"
            )
        ]

        XCTAssertEqual(
            WorkbenchCommandPalette().filter(commands, query: "slugger").map(\.payload),
            ["slugger"]
        )
    }

    func testOpenSettingsCommandIDIsPresent() {
        // The Settings sheet is reachable via the ⌘K palette as well as ⌘,
        // so guard the command ID exists in the enum's case list.
        XCTAssertTrue(WorkbenchCommandID.allCases.contains(.openSettings))
    }
}
