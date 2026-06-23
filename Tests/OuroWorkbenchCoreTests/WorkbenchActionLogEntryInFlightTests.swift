import XCTest
@testable import OuroWorkbenchCore

/// Backward-compatibility + default behavior for `WorkbenchActionLogEntry.isInFlight`
/// — the flag the boss action-log false-green fix threads through so an in-flight
/// optimistic ack renders neutral (pending) rather than a green check.
///
/// `isInFlight` is a NON-OPTIONAL `Bool`, so Swift's synthesized Codable would
/// THROW on a persisted entry that predates the field (the key is absent). The
/// entry therefore decodes via a custom `init(from:)` that defaults the missing
/// key to `false` — old `state.actionLog` JSON must still load, and a pre-fix
/// entry must read as NOT-in-flight (its settled `succeeded` flag is the truth).
final class WorkbenchActionLogEntryInFlightTests: XCTestCase {
    func testDefaultIsNotInFlight() {
        let entry = WorkbenchActionLogEntry(source: "external", action: "verifyProvider", result: "ok", succeeded: true)
        XCTAssertFalse(entry.isInFlight, "a freshly-constructed entry defaults to not-in-flight")
    }

    func testInFlightRoundTripsThroughCodable() throws {
        let entry = WorkbenchActionLogEntry(
            source: "external", action: "repairAgent",
            result: "Working on getting Serpent ready…", succeeded: true, isInFlight: true
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(WorkbenchActionLogEntry.self, from: data)
        XCTAssertTrue(decoded.isInFlight, "an in-flight entry round-trips its flag")
        XCTAssertEqual(decoded, entry)
    }

    func testNotInFlightRoundTripsThroughCodable() throws {
        let entry = WorkbenchActionLogEntry(
            source: "external", action: "repairAgent",
            result: "ouro repair --agent Serpent: repaired", succeeded: true, isInFlight: false
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(WorkbenchActionLogEntry.self, from: data)
        XCTAssertFalse(decoded.isInFlight)
        XCTAssertEqual(decoded, entry)
    }

    func testOldJSONWithoutInFlightKeyDecodesToFalse() throws {
        // A persisted pre-fix entry: no `isInFlight` key at all. It must decode
        // (not throw) and default to false — its settled `succeeded` is the truth.
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "occurredAt": 0,
          "source": "native",
          "action": "verifyProvider",
          "result": "ouro auth verify --agent Serpent: verified",
          "succeeded": true
        }
        """
        let decoded = try JSONDecoder().decode(WorkbenchActionLogEntry.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.isInFlight, "a pre-fix entry (no key) reads as not-in-flight")
        XCTAssertEqual(decoded.succeeded, true)
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.action, "verifyProvider")
    }

    func testOldJSONWithoutOptionalFieldsStillDecodes() throws {
        // The pre-existing optional fields (`targetEntryId`, `targetName`,
        // `requestId`) are still absent-tolerant alongside the new key default.
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "occurredAt": 0,
          "source": "external",
          "action": "ensureDaemon",
          "result": "Skipped",
          "succeeded": false
        }
        """
        let decoded = try JSONDecoder().decode(WorkbenchActionLogEntry.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.isInFlight)
        XCTAssertNil(decoded.targetEntryId)
        XCTAssertNil(decoded.targetName)
        XCTAssertNil(decoded.requestId)
    }
}
