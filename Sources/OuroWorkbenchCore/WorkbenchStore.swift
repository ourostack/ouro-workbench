import Foundation

/// The result of trying to move an unreadable state file aside before the app
/// resets to empty + auto-saves. This is a CHECKED value, not a fire-and-forget
/// `try?`: the caller MUST distinguish the two so it never claims a recovery
/// location that doesn't exist.
///
/// - `.moved`: the file was relocated to `quarantineURL`. The live `stateURL` is
///   now empty, so resetting to empty state + saving is safe — and the operator
///   can recover from `quarantineURL`.
/// - `.moveFailed`: the move threw. The original is STILL at `stateURL`. The
///   caller must NOT reset-to-empty + save (that atomic overwrite would clobber
///   the only surviving copy), and must NOT tell the operator anything is at
///   `attemptedURL` — nothing is.
public enum QuarantineOutcome: Equatable, Sendable {
    case moved(quarantineURL: URL)
    case moveFailed(attemptedURL: URL, reason: String)
}

public enum WorkbenchStoreError: Error, Equatable {
    case unsupportedStateVersion(Int)
    /// The state file existed but couldn't be read/decoded. `preserved` records
    /// what happened to the original — either it was `.moved` aside (safe to
    /// reset+save) or the move `.moveFailed` and it's still at `stateURL` (the
    /// caller must NOT overwrite it). Carrying the outcome means the error can't
    /// claim a recovery location that doesn't exist. Cause described by `reason`.
    case unreadableState(preserved: QuarantineOutcome, reason: String)

    public static func == (lhs: WorkbenchStoreError, rhs: WorkbenchStoreError) -> Bool {
        switch (lhs, rhs) {
        case let (.unsupportedStateVersion(a), .unsupportedStateVersion(b)):
            return a == b
        case let (.unreadableState(a, _), .unreadableState(b, _)):
            // Reason is incidental; the outcome (and its path) is load-bearing.
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
    /// data. Returns the error to throw, carrying the CHECKED move outcome so
    /// the caller can never report a recovery location that doesn't exist.
    private func quarantine(reason: String) -> WorkbenchStoreError {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let quarantineURL = stateURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(stateURL.lastPathComponent).corrupt-\(stamp)")
        let outcome = Self.quarantineMove(
            stateURL: stateURL,
            quarantineURL: quarantineURL,
            fileManager: .default
        )
        return WorkbenchStoreError.unreadableState(preserved: outcome, reason: reason)
    }

    /// Pure move of `stateURL` → `quarantineURL`, classified into a checked
    /// `QuarantineOutcome`. Extracted so it's unit-testable by passing a
    /// `quarantineURL` that already exists as a non-empty directory (which
    /// forces `moveItem` to throw deterministically — no timestamp racing).
    ///
    /// On success → `.moved`; on any throw → `.moveFailed`, and the original is
    /// guaranteed to be untouched at `stateURL` (the throw happened before any
    /// destructive step), so the caller must not overwrite it.
    public static func quarantineMove(
        stateURL: URL,
        quarantineURL: URL,
        fileManager: FileManager
    ) -> QuarantineOutcome {
        do {
            try fileManager.moveItem(at: stateURL, to: quarantineURL)
            return .moved(quarantineURL: quarantineURL)
        } catch {
            return .moveFailed(attemptedURL: quarantineURL, reason: error.localizedDescription)
        }
    }

    /// COPY the current on-disk `stateURL` to a timestamped `.salvage-<stamp>`
    /// sibling and return its URL. Used when a lenient decode dropped rows: the
    /// loaded state is about to be re-saved over `stateURL` WITHOUT the dropped
    /// rows, so we preserve the original (pre-drop) bytes first.
    ///
    /// `copyItem`, NOT `moveItem` — the live file must stay in place because the
    /// imminent re-save writes over it; moving it would defeat the re-save and
    /// strand the workspace. Throws if the live file is missing or the copy
    /// fails (the caller treats salvage as best-effort via `try?`).
    public func writeSalvageCopy() throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let salvageURL = stateURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(stateURL.lastPathComponent).salvage-\(stamp)")
        try FileManager.default.copyItem(at: stateURL, to: salvageURL)
        return salvageURL
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
