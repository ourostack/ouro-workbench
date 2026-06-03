import XCTest
@testable import OuroWorkbenchCore

final class ProcessEntryPinTests: XCTestCase {
    private func entry(_ name: String, pinned: Bool) -> ProcessEntry {
        ProcessEntry(
            projectId: UUID(),
            name: name,
            kind: .terminalAgent,
            executable: "/bin/zsh",
            workingDirectory: "/tmp",
            isPinned: pinned
        )
    }

    func testIsPinnedDefaultsFalse() {
        let e = ProcessEntry(
            projectId: UUID(),
            name: "x",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            workingDirectory: "/tmp"
        )
        XCTAssertFalse(e.isPinned)
    }

    func testIsPinnedSurvivesCodingRoundTrip() throws {
        let pinned = entry("pinned", pinned: true)
        let data = try JSONEncoder().encode(pinned)
        let decoded = try JSONDecoder().decode(ProcessEntry.self, from: data)
        XCTAssertTrue(decoded.isPinned)
    }

    func testDecodesWithoutIsPinnedForBackwardsCompatibility() throws {
        // Pre-pin persisted entries lack the key; decode must default to
        // false rather than throwing.
        let legacyJSON = """
        {
            "id": "00000000-0000-0000-0000-000000000009",
            "projectId": "00000000-0000-0000-0000-0000000000aa",
            "name": "legacy",
            "kind": "terminalAgent",
            "executable": "/bin/zsh",
            "arguments": [],
            "workingDirectory": "/tmp",
            "trust": "untrusted",
            "autoResume": false
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ProcessEntry.self, from: legacyJSON)
        XCTAssertFalse(decoded.isPinned)
        XCTAssertEqual(decoded.name, "legacy")
    }

    func testDecodesIgnoringStaleDeskTaskSlugKey() throws {
        // The Workbench->desk mirror (and its `deskTaskSlug` field) was removed.
        // Workspace state persisted before that removal still carries the stale
        // key; decode must ignore it rather than throwing.
        let legacyJSON = """
        {
            "id": "00000000-0000-0000-0000-000000000009",
            "projectId": "00000000-0000-0000-0000-0000000000aa",
            "name": "legacy",
            "kind": "terminalAgent",
            "executable": "/bin/zsh",
            "arguments": [],
            "workingDirectory": "/tmp",
            "trust": "untrusted",
            "autoResume": false,
            "deskTaskSlug": "ship-the-thing"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ProcessEntry.self, from: legacyJSON)
        XCTAssertEqual(decoded.name, "legacy")
    }

    /// Mirrors the WorkbenchViewModel.sessionEntries partition: pinned float
    /// to the top, preserving stored order within each partition.
    func testPinnedPartitionIsStableAndPinnedFirst() {
        let entries = [
            entry("a", pinned: false),
            entry("b", pinned: true),
            entry("c", pinned: false),
            entry("d", pinned: true)
        ]
        let sorted = entries.filter(\.isPinned) + entries.filter { !$0.isPinned }
        XCTAssertEqual(sorted.map(\.name), ["b", "d", "a", "c"])
    }
}
