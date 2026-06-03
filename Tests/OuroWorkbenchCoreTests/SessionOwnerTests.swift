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

    // MARK: - Forward schema drift

    func testUnknownOwnerKindDecodesAsHumanNotThrowing() throws {
        // A future build could persist an owner `kind` this build doesn't know.
        // It must decode to `.human` rather than throwing — a throw is fatal
        // here because `ProcessEntry` decodes via `FailableDecodable`, so it
        // would drop the entire session row, not just the owner field.
        let json = """
        { "kind": "somefuturekind" }
        """.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(SessionOwner.self, from: json), .human)
    }

    func testAgentOwnerWithNameDecodes() throws {
        let json = """
        { "kind": "agent", "name": "x" }
        """.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(SessionOwner.self, from: json), .agent(name: "x"))
    }

    func testAgentOwnerMissingNameFallsBackToHuman() throws {
        // A malformed agent owner with no `name` must not throw (which would
        // drop the whole row) — it falls back to the human operator.
        let json = """
        { "kind": "agent" }
        """.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(SessionOwner.self, from: json), .human)
    }

    func testEntryWithUnknownOwnerKindIsPreservedNotDropped() throws {
        // The end-to-end guarantee: a ProcessEntry whose persisted owner has an
        // unrecognized kind survives decoding (owner falls back to `.human`)
        // instead of being silently dropped by the failable decoder.
        let json = """
        {
            "id": "00000000-0000-0000-0000-00000000000b",
            "projectId": "00000000-0000-0000-0000-0000000000bb",
            "name": "drifted",
            "kind": "terminalAgent",
            "executable": "/bin/zsh",
            "arguments": [],
            "workingDirectory": "/tmp",
            "trust": "trusted",
            "autoResume": false,
            "owner": { "kind": "somefuturekind" }
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ProcessEntry.self, from: json)
        XCTAssertEqual(decoded.name, "drifted")
        XCTAssertEqual(decoded.owner, .human)
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
