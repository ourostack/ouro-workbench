import XCTest
@testable import OuroWorkbenchCore

final class SessionOwnerTests: XCTestCase {
    private func entry(_ name: String, owner: SessionOwner = .human) -> ProcessEntry {
        ProcessEntry(
            projectId: UUID(),
            name: name,
            kind: .terminalAgent,
            executable: "/bin/zsh",
            workingDirectory: "/tmp",
            owner: owner
        )
    }

    // MARK: - SessionOwner

    func testHumanRoundTrips() throws {
        let data = try JSONEncoder().encode(SessionOwner.human)
        let decoded = try JSONDecoder().decode(SessionOwner.self, from: data)
        XCTAssertEqual(decoded, .human)
        XCTAssertNil(decoded.agentName)
        XCTAssertEqual(decoded.displayName, "You")
    }

    func testAgentRoundTrips() throws {
        let original = SessionOwner.agent(name: "slugger")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionOwner.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.agentName, "slugger")
        XCTAssertEqual(decoded.displayName, "slugger")
    }

    // MARK: - Sidebar badge

    func testHumanHasNoSidebarBadge() {
        XCTAssertNil(SessionOwner.human.sidebarBadge)
    }

    func testAgentHasSidebarBadge() throws {
        let badge = try XCTUnwrap(SessionOwner.agent(name: "slugger").sidebarBadge)
        XCTAssertEqual(badge.label, "slugger")
        XCTAssertFalse(badge.symbol.isEmpty)
    }

    // MARK: - ProcessEntry integration

    func testOwnerDefaultsHuman() {
        XCTAssertEqual(entry("x").owner, .human)
    }

    func testAgentOwnerSurvivesCodingRoundTrip() throws {
        let owned = entry("owned", owner: .agent(name: "slugger"))
        let data = try JSONEncoder().encode(owned)
        let decoded = try JSONDecoder().decode(ProcessEntry.self, from: data)
        XCTAssertEqual(decoded.owner, .agent(name: "slugger"))
    }

    func testDecodesWithoutOwnerForBackwardsCompatibility() throws {
        // Pre-owner persisted entries lack the key; decode must default to
        // `.human` rather than throwing.
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
        XCTAssertEqual(decoded.owner, .human)
        XCTAssertEqual(decoded.name, "legacy")
    }

    func testEncodedEntryOmittingOwnerKeyDecodesAsHuman() throws {
        // Encode a normal (human-owned) entry, strip the `owner` key from the
        // JSON, and confirm it still decodes as `.human` — proving the
        // if-present decode handles state written before `owner` existed.
        let data = try JSONEncoder().encode(entry("strip"))
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        json.removeValue(forKey: "owner")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(ProcessEntry.self, from: stripped)
        XCTAssertEqual(decoded.owner, .human)
    }
}
