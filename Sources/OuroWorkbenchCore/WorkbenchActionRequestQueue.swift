import Foundation

public struct WorkbenchActionRequest: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var source: String
    public var action: BossWorkbenchAction

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        source: String,
        action: BossWorkbenchAction
    ) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.action = action
    }
}

public final class WorkbenchActionRequestQueue {
    public let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
    }

    public convenience init(paths: WorkbenchPaths = .defaultPaths()) {
        self.init(directoryURL: paths.actionRequestsURL)
    }

    public func enqueue(_ request: WorkbenchActionRequest) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(request)
        let url = directoryURL.appendingPathComponent("\(request.createdAt.timeIntervalSince1970)-\(request.id.uuidString).json")
        try data.write(to: url, options: [.atomic])
    }

    public func drain() throws -> [WorkbenchActionRequest] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return []
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var requests: [WorkbenchActionRequest] = []
        for url in urls {
            let data = try Data(contentsOf: url)
            requests.append(try decoder.decode(WorkbenchActionRequest.self, from: data))
            try FileManager.default.removeItem(at: url)
        }
        return requests
    }
}
