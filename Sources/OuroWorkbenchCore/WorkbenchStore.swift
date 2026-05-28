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

    /// Load the workspace state.
    ///
    /// - Parameter quarantineCorruptFile: when `true` (the owning app), a file
    ///   that can't be read/decoded is moved aside to a timestamped sibling so
    ///   the app's empty-state fallback + auto-save can't clobber it. **Pass
    ///   `false` for read-only consumers** (e.g. the MCP server): they share
    ///   the same `stateURL` but don't own it, and must never move the live
    ///   file out from under the running app — a transient read blip or a
    ///   schema bump seen by a stale binary would otherwise destroy good state.
    ///   In read-only mode a failure throws the underlying error without
    ///   touching the file.
    public func load(quarantineCorruptFile: Bool = true) throws -> WorkspaceState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return WorkspaceState()
        }

        let data: Data
        do {
            data = try Data(contentsOf: stateURL)
        } catch {
            if quarantineCorruptFile {
                throw quarantine(reason: "read failed: \(error.localizedDescription)")
            }
            throw error
        }

        do {
            let state = try decoder.decode(WorkspaceState.self, from: data)
            guard state.schemaVersion == 1 else {
                if quarantineCorruptFile {
                    throw quarantine(reason: "unsupported schema version \(state.schemaVersion)")
                }
                throw WorkbenchStoreError.unsupportedStateVersion(state.schemaVersion)
            }
            return state
        } catch let error as WorkbenchStoreError {
            throw error
        } catch {
            if quarantineCorruptFile {
                throw quarantine(reason: "decode failed: \(error.localizedDescription)")
            }
            throw error
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
