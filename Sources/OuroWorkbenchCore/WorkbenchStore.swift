import Foundation

public enum WorkbenchStoreError: Error, Equatable {
    case unsupportedStateVersion(Int)
    /// The state file existed but couldn't be read/decoded. It has been moved
    /// aside to `quarantineURL` so the user's data isn't overwritten by the
    /// empty fallback state. Underlying cause described by `reason`.
    case unreadableState(quarantineURL: URL, reason: String)

    public static func == (lhs: WorkbenchStoreError, rhs: WorkbenchStoreError) -> Bool {
        switch (lhs, rhs) {
        case let (.unsupportedStateVersion(a), .unsupportedStateVersion(b)):
            return a == b
        case let (.unreadableState(a, _), .unreadableState(b, _)):
            return a == b
        default:
            return false
        }
    }
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

        let data: Data
        do {
            data = try Data(contentsOf: stateURL)
        } catch {
            throw quarantine(reason: "read failed: \(error.localizedDescription)")
        }

        do {
            let state = try decoder.decode(WorkspaceState.self, from: data)
            guard state.schemaVersion == 1 else {
                // A version we don't understand: quarantine rather than risk
                // mis-reading it, so the original is preserved for migration.
                throw quarantine(reason: "unsupported schema version \(state.schemaVersion)")
            }
            return state
        } catch let error as WorkbenchStoreError {
            throw error
        } catch {
            throw quarantine(reason: "decode failed: \(error.localizedDescription)")
        }
    }

    /// Move the unreadable state file aside to a timestamped sibling so a
    /// subsequent save of the empty fallback state can't destroy the user's
    /// data. Returns the error to throw (with the quarantine location).
    private func quarantine(reason: String) -> WorkbenchStoreError {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let quarantineURL = stateURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(stateURL.lastPathComponent).corrupt-\(stamp)")
        try? FileManager.default.moveItem(at: stateURL, to: quarantineURL)
        return WorkbenchStoreError.unreadableState(quarantineURL: quarantineURL, reason: reason)
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
