import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class HerdrIntegrationHealthTests: XCTestCase {
    func testReaderPublishesNamespacedSourceAwareHealthWithoutOwningPanes() throws {
        let observedAt = Date(timeIntervalSince1970: 1_990)
        let now = Date(timeIntervalSince1970: 2_000)
        let observation = RemoteHealthObservation(
            schemaVersion: 1,
            observedAt: observedAt,
            checks: [
                RemoteHealthCheck(name: "herdr-active-generation", source: "/runtime/herdr.sock", observedAt: observedAt, state: .healthy, detail: "one exact pane"),
                RemoteHealthCheck(name: "mobile-relay", source: "/runtime/relay-state.json", observedAt: observedAt, state: .healthy, detail: "ready")
            ]
        )
        let data = try JSONEncoder.remoteHealth.encode(observation)

        let health = HerdrIntegrationHealthReader.read(
            sourceURL: URL(fileURLWithPath: "/private/runtime/observations/latest.json"),
            now: now,
            staleAfter: 60,
            read: { _, _ in data }
        )

        XCTAssertEqual(health.schemaVersion, 1)
        XCTAssertEqual(health.namespace, "herdrIntegrationHealth")
        XCTAssertEqual(health.canonicalOwner, "Herdr")
        XCTAssertEqual(health.summary.source, "/private/runtime/observations/latest.json")
        XCTAssertEqual(health.summary.freshness, .fresh)
        XCTAssertEqual(health.summary.state, .healthy)
        XCTAssertEqual(health.checks.map(\.name), ["herdr-active-generation", "mobile-relay"])
        XCTAssertTrue(health.checks.allSatisfy { $0.freshness == .fresh && $0.state == .healthy })
        let encoded = try health.jsonData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["processEntries"])
        XCTAssertNil(object["panes"])
        XCTAssertEqual(object["canonicalOwner"] as? String, "Herdr")
    }

    func testReaderPreservesSpecificFailureAndNeverCallsEmptyOrStaleHealthy() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let cases: [([RemoteHealthCheck], RemoteHealthState, RemoteHealthFreshness)] = [
            ([], .unknown, .fresh),
            ([.init(name: "old", source: "socket", observedAt: Date(timeIntervalSince1970: 1_000), state: .healthy, detail: "was healthy")], .unknown, .stale),
            ([.init(name: "missing", source: "file", observedAt: nil, state: .unavailable, detail: "missing")], .unavailable, .fresh),
            ([.init(name: "account", source: "gh", observedAt: now, state: .accountMismatch, detail: "wrong")], .accountMismatch, .fresh),
            ([.init(name: "blocked", source: "ledger", observedAt: now, state: .blocked, detail: "repair")], .blocked, .fresh),
            ([.init(name: "tripped", source: "relay", observedAt: now, state: .tripped, detail: "circuit")], .tripped, .fresh),
            ([.init(name: "corrupt", source: "manifest", observedAt: now, state: .corrupt, detail: "invalid")], .corrupt, .fresh)
        ]

        for (index, fixture) in cases.enumerated() {
            let observation = RemoteHealthObservation(schemaVersion: 1, observedAt: now, checks: fixture.0)
            let data = try JSONEncoder.remoteHealth.encode(observation)
            let health = HerdrIntegrationHealthReader.read(
                sourceURL: URL(fileURLWithPath: "/private/runtime/fixture-\(index).json"),
                now: now,
                staleAfter: 60,
                read: { _, _ in data }
            )
            XCTAssertEqual(health.summary.state, fixture.1, "fixture \(index)")
            XCTAssertEqual(health.summary.freshness, fixture.2, "fixture \(index)")
        }
    }

    func testReaderFailsClosedForUnavailableInvalidAndNewerObservations() throws {
        let source = URL(fileURLWithPath: "/private/runtime/observations/latest.json")
        let unavailable = HerdrIntegrationHealthReader.read(sourceURL: source, now: Date(), read: { _, _ in throw RemoteControlError.invalidConfiguration("fixture secret") })
        XCTAssertEqual(unavailable.summary.state, .unavailable)
        XCTAssertEqual(unavailable.summary.freshness, .unknown)
        XCTAssertTrue(unavailable.checks.isEmpty)
        XCTAssertFalse(unavailable.summary.detail.contains("fixture secret"))

        let invalidFixtures = [
            Data("not-json".utf8),
            Data(repeating: 0x20, count: HerdrIntegrationHealthReader.maximumObservationBytes + 1),
            Data(#"[]"#.utf8),
            Data(#"{"schemaVersion":2,"observedAt":"1970-01-01T00:00:00Z","checks":[]}"#.utf8),
            Data(#"{"schemaVersion":1,"observedAt":"1970-01-01T00:00:00Z","checks":[],"future":true}"#.utf8),
            Data(#"{"schemaVersion":1,"checks":[]}"#.utf8),
            Data(#"{"schemaVersion":1,"observedAt":1,"checks":[]}"#.utf8),
            Data(#"{"schemaVersion":1,"observedAt":"1970-01-01T00:00:00Z","checks":{}}"#.utf8),
            Data(#"{"schemaVersion":1,"observedAt":"1970-01-01T00:00:00Z","checks":[{"name":"a","source":"b","state":"healthy","detail":"c","future":true}]}"#.utf8),
            Data(#"{"schemaVersion":1,"observedAt":"1970-01-01T00:00:00Z","checks":[{"name":1,"source":"b","state":"healthy","detail":"c"}]}"#.utf8),
            Data(#"{"schemaVersion":1,"observedAt":"1970-01-01T00:00:00Z","checks":[{"name":"a","source":"b","observedAt":1,"state":"healthy","detail":"c"}]}"#.utf8),
            Data(#"{"schemaVersion":1,"observedAt":"not-a-date","checks":[]}"#.utf8)
        ]
        for data in invalidFixtures {
            let health = HerdrIntegrationHealthReader.read(sourceURL: source, now: Date(), read: { _, _ in data })
            XCTAssertEqual(health.summary.state, .corrupt)
            XCTAssertEqual(health.summary.freshness, .unknown)
            XCTAssertTrue(health.checks.isEmpty)
        }
    }

    func testReaderUsesPrivateBoundedFileAndStableDefaultLocation() throws {
        let root = try remoteTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("latest.json")
        let observation = RemoteHealthObservation(schemaVersion: 1, observedAt: Date(timeIntervalSince1970: 20), checks: [])
        try JSONEncoder.remoteHealth.encode(observation).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)

        let health = HerdrIntegrationHealthReader.read(sourceURL: source, now: Date(timeIntervalSince1970: 21))
        XCTAssertEqual(health.summary.state, .unknown)
        XCTAssertEqual(health.summary.source, source.path)
        XCTAssertEqual(
            HerdrIntegrationHealthReader.defaultObservationURL(homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)).path,
            "/Users/example/.local/state/ouro-mobile-control-plane/observer/observations/latest.json"
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
        XCTAssertEqual(HerdrIntegrationHealthReader.read(sourceURL: source, now: Date()).summary.state, .unavailable)
    }

    func testReaderMarksAnOldObservationStaleEvenWhenItContainsNoChecks() throws {
        let observation = RemoteHealthObservation(schemaVersion: 1, observedAt: Date(timeIntervalSince1970: 10), checks: [])
        let health = HerdrIntegrationHealthReader.read(
            sourceURL: URL(fileURLWithPath: "/private/runtime/old.json"),
            now: Date(timeIntervalSince1970: 100),
            staleAfter: 60,
            read: { _, _ in try JSONEncoder.remoteHealth.encode(observation) }
        )

        XCTAssertEqual(health.summary.freshness, .stale)
        XCTAssertEqual(health.summary.state, .unknown)
    }
}

private extension JSONEncoder {
    static var remoteHealth: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
