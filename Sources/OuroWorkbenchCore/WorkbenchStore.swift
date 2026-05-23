import Foundation

public enum WorkbenchStoreError: Error, Equatable {
    case unsupportedStateVersion(Int)
}

public final class WorkbenchStore {
    public let stateURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(stateURL: URL) {
        self.stateURL = stateURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
    }

    public convenience init(paths: WorkbenchPaths = .defaultPaths()) {
        self.init(stateURL: paths.stateURL)
    }

    public func load() throws -> WorkspaceState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return WorkspaceState()
        }

        let data = try Data(contentsOf: stateURL)
        let state = try decoder.decode(WorkspaceState.self, from: data)
        guard state.schemaVersion == 1 else {
            throw WorkbenchStoreError.unsupportedStateVersion(state.schemaVersion)
        }
        return state
    }

    public func save(_ state: WorkspaceState) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var updated = state
        updated.updatedAt = Date()
        let data = try encoder.encode(updated)
        try data.write(to: stateURL, options: [.atomic])
    }
}
