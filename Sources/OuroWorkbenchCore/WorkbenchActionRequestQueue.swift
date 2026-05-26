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
    public let rejectedDirectoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.rejectedDirectoryURL = directoryURL.appendingPathComponent("rejected", isDirectory: true)
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

        var decodedRequests: [(url: URL, request: WorkbenchActionRequest)] = []
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let request = try decoder.decode(WorkbenchActionRequest.self, from: data)
                decodedRequests.append((url: url, request: request))
            } catch {
                quarantineInvalidRequestFile(url)
            }
        }

        let sortedRequests = decodedRequests.sorted { lhs, rhs in
            if lhs.request.createdAt != rhs.request.createdAt {
                return lhs.request.createdAt < rhs.request.createdAt
            }
            return lhs.request.id.uuidString < rhs.request.id.uuidString
        }
        for item in sortedRequests {
            try FileManager.default.removeItem(at: item.url)
        }
        return sortedRequests.map(\.request)
    }

    private func quarantineInvalidRequestFile(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: rejectedDirectoryURL, withIntermediateDirectories: true)
            var destination = rejectedDirectoryURL.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                destination = rejectedDirectoryURL.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            }
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
