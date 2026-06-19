import XCTest
@testable import OuroWorkbenchCore

final class AgentSessionRecordTests: XCTestCase {
    // MARK: - AgentHarness

    func testHarnessRawValuesAreStable() {
        XCTAssertEqual(AgentHarness.claudeCode.rawValue, "claudeCode")
        XCTAssertEqual(AgentHarness.githubCopilotCLI.rawValue, "githubCopilotCLI")
        XCTAssertEqual(AgentHarness.openAICodex.rawValue, "openAICodex")
        XCTAssertEqual(AgentHarness.custom.rawValue, "custom")
    }

    func testHarnessDecodesKnownRawValues() throws {
        for harness in AgentHarness.allCases {
            let json = Data("\"\(harness.rawValue)\"".utf8)
            let decoded = try JSONDecoder().decode(AgentHarness.self, from: json)
            XCTAssertEqual(decoded, harness)
        }
    }

    func testHarnessDecodesUnknownRawValueToCustom() throws {
        let json = Data("\"somethingNewFromANewerBuild\"".utf8)
        let decoded = try JSONDecoder().decode(AgentHarness.self, from: json)
        XCTAssertEqual(decoded, .custom)
    }

    func testHarnessEncodesRawValue() throws {
        let data = try JSONEncoder().encode(AgentHarness.openAICodex)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"openAICodex\"")
    }

    // MARK: - AgentSessionRecord

    func testRecordRoundTripsWithAllFields() throws {
        let record = AgentSessionRecord(
            harness: .claudeCode,
            sessionId: "abc-123",
            cwd: "/Users/me/project",
            repository: "owner/repo",
            branch: "main",
            title: "Fix the thing",
            lastActive: Date(timeIntervalSince1970: 1_700_000_000),
            running: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let decoded = try decoder.decode(AgentSessionRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }

    func testRecordRoundTripsWithNilOptionalFields() throws {
        let record = AgentSessionRecord(
            harness: .githubCopilotCLI,
            sessionId: "only-id",
            cwd: "/tmp",
            repository: nil,
            branch: nil,
            title: nil,
            lastActive: nil,
            running: false
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(AgentSessionRecord.self, from: data)
        XCTAssertEqual(decoded, record)
        XCTAssertNil(decoded.repository)
        XCTAssertNil(decoded.branch)
        XCTAssertNil(decoded.title)
        XCTAssertNil(decoded.lastActive)
    }

    func testRecordIdIsHarnessAndSessionId() {
        let record = AgentSessionRecord(
            harness: .openAICodex,
            sessionId: "sid",
            cwd: "/x",
            running: false
        )
        XCTAssertEqual(record.id, "openAICodex:sid")
    }

    func testRecordDefaultsOptionalsToNil() {
        let record = AgentSessionRecord(
            harness: .custom,
            sessionId: "s",
            cwd: "/c",
            running: true
        )
        XCTAssertNil(record.repository)
        XCTAssertNil(record.branch)
        XCTAssertNil(record.title)
        XCTAssertNil(record.lastActive)
        XCTAssertTrue(record.running)
    }

    func testRecordEquatableDistinguishesFields() {
        let base = AgentSessionRecord(harness: .claudeCode, sessionId: "a", cwd: "/c", running: false)
        XCTAssertNotEqual(base, AgentSessionRecord(harness: .openAICodex, sessionId: "a", cwd: "/c", running: false))
        XCTAssertNotEqual(base, AgentSessionRecord(harness: .claudeCode, sessionId: "b", cwd: "/c", running: false))
        XCTAssertNotEqual(base, AgentSessionRecord(harness: .claudeCode, sessionId: "a", cwd: "/d", running: false))
        XCTAssertNotEqual(base, AgentSessionRecord(harness: .claudeCode, sessionId: "a", cwd: "/c", running: true))
    }
}
