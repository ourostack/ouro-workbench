import Foundation

public struct RemoteHealthObservation: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let observedAt: Date
    public let checks: [RemoteHealthCheck]

    public init(schemaVersion: Int, observedAt: Date, checks: [RemoteHealthCheck]) {
        self.schemaVersion = schemaVersion
        self.observedAt = observedAt
        self.checks = checks
    }
}

public struct HerdrIntegrationHealth: Codable, Equatable, Sendable {
    public static let toolName = "workbench_herdr_integration_health"
    public static let toolDescription = "Read the bounded Herdr integration observation as namespaced health. Read-only: Herdr remains the canonical owner of panes and sessions."

    public let schemaVersion: Int
    public let namespace: String
    public let canonicalOwner: String
    public let summary: RemoteDoctorCheck
    public let checks: [RemoteDoctorCheck]

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

public enum HerdrIntegrationHealthReader {
    public static let maximumObservationBytes = 65_536
    public static let defaultStaleAfter: TimeInterval = 120

    public static func defaultObservationURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".local/state/ouro-mobile-control-plane/observer/observations/latest.json")
    }

    public static func read(
        sourceURL: URL,
        now: Date,
        staleAfter: TimeInterval = defaultStaleAfter,
        read: (String, Int) throws -> Data = { try RemotePrivateFile.read(path: $0, maximumBytes: $1) }
    ) -> HerdrIntegrationHealth {
        let source = sourceURL.standardizedFileURL.path
        let data: Data
        do {
            data = try read(source, maximumObservationBytes)
        } catch {
            return health(source: source, observedAt: nil, freshness: .unknown, state: .unavailable, detail: "Herdr integration observation is unavailable.", checks: [])
        }

        let observation: RemoteHealthObservation
        do {
            observation = try decodeStrict(data)
        } catch {
            return health(source: source, observedAt: nil, freshness: .unknown, state: .corrupt, detail: "Herdr integration observation is invalid.", checks: [])
        }

        let report = RemoteDoctor.report(checks: observation.checks, now: now, staleAfter: staleAfter, redacting: [])
        let observationFreshness: RemoteHealthFreshness = now.timeIntervalSince(observation.observedAt) > staleAfter ? .stale : .fresh
        let freshness: RemoteHealthFreshness = report.checks.contains(where: { $0.freshness == .stale }) ? .stale : observationFreshness
        let state = aggregate(report.checks.map(\.state))
        let detail = report.checks.isEmpty ? "No Herdr integration checks were observed." : "Read \(report.checks.count) Herdr integration check\(report.checks.count == 1 ? "" : "s")."
        return health(source: source, observedAt: observation.observedAt, freshness: freshness, state: state, detail: detail, checks: report.checks)
    }

    private static func decodeStrict(_ data: Data) throws -> RemoteHealthObservation {
        guard data.count <= maximumObservationBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["schemaVersion", "observedAt", "checks"],
              root["schemaVersion"] as? Int == 1,
              root["observedAt"] is String,
              let checks = root["checks"] as? [[String: Any]],
              checks.allSatisfy(validCheck)
        else {
            throw RemoteControlError.observation("invalid Herdr integration observation")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RemoteHealthObservation.self, from: data)
    }

    private static func validCheck(_ check: [String: Any]) -> Bool {
        let keys = Set(check.keys)
        guard keys == ["name", "source", "state", "detail"] || keys == ["name", "source", "observedAt", "state", "detail"] else { return false }
        guard check["name"] is String,
              check["source"] is String,
              check["state"] is String,
              check["detail"] is String
        else { return false }
        return check["observedAt"] == nil || check["observedAt"] is String
    }

    private static func aggregate(_ states: [RemoteHealthState]) -> RemoteHealthState {
        let priority: [RemoteHealthState] = [.corrupt, .tripped, .blocked, .accountMismatch, .degraded, .unavailable, .unknown, .healthy]
        return priority.first(where: states.contains) ?? .unknown
    }

    private static func health(
        source: String,
        observedAt: Date?,
        freshness: RemoteHealthFreshness,
        state: RemoteHealthState,
        detail: String,
        checks: [RemoteDoctorCheck]
    ) -> HerdrIntegrationHealth {
        HerdrIntegrationHealth(
            schemaVersion: 1,
            namespace: "herdrIntegrationHealth",
            canonicalOwner: "Herdr",
            summary: RemoteDoctorCheck(name: "herdr-integration", source: source, observedAt: observedAt, freshness: freshness, state: state, detail: detail),
            checks: checks
        )
    }
}
