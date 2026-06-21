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

    /// Stable identity of *what this request does*, ignoring the per-request
    /// `id`/`createdAt`/`source`. Two requests with the same fingerprint enqueue
    /// the same effect (launch the same entry, send the same input, …), so the
    /// queue treats the second as a duplicate. Covers the action kind plus every
    /// field that changes the applied behaviour: entry, text, appendNewline,
    /// group, name, command, workingDirectory.
    var fingerprint: String {
        let parts: [String] = [
            action.action.rawValue,
            action.entry ?? "",
            action.text ?? "",
            action.appendNewline ? "1" : "0",
            action.group ?? "",
            action.name ?? "",
            action.command ?? "",
            action.workingDirectory ?? "",
        ]
        // Length-prefix each field so concatenation can't collide across
        // differing field boundaries (e.g. name="a"+command="b" vs name="ab").
        return parts.map { "\($0.count):\($0)" }.joined(separator: "|")
    }
}

public final class WorkbenchActionRequestQueue {
    public let directoryURL: URL
    public let rejectedDirectoryURL: URL
    /// Holding area for requests that `drain()` has handed to the app but the
    /// app hasn't yet confirmed it applied. Gives at-least-once delivery: a
    /// crash between drain and apply leaves the request file here, and
    /// `recoverUnconfirmed()` replays it on the next launch.
    public let processingDirectoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.rejectedDirectoryURL = directoryURL.appendingPathComponent("rejected", isDirectory: true)
        self.processingDirectoryURL = directoryURL.appendingPathComponent("processing", isDirectory: true)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
    }

    public convenience init(paths: WorkbenchPaths = .defaultPaths()) {
        self.init(directoryURL: paths.actionRequestsURL)
    }

    /// Enqueue a request, dropping it as a no-op when an identical request
    /// (same action fingerprint — see `WorkbenchActionRequest.fingerprint`) is
    /// already pending in the queue dir. This makes re-enqueue idempotent: a
    /// reasoning boss that returns an empty FINAL reply after already calling
    /// its Workbench tools can be retried with a fresh turn without the same
    /// `request_action` enqueueing a duplicate `launch`/`sendInput` that would
    /// drain and execute twice.
    public func enqueue(_ request: WorkbenchActionRequest) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if hasPendingDuplicate(of: request) {
            return
        }
        let data = try encoder.encode(request)
        let url = directoryURL.appendingPathComponent("\(request.createdAt.timeIntervalSince1970)-\(request.id.uuidString).json")
        try data.write(to: url, options: [.atomic])
    }

    /// Drain pending requests, MOVING each request file into `processing/`
    /// (rather than deleting it) before returning the decoded requests. The
    /// returned request's `id` matches its `processing/` filename so the app can
    /// `confirmApplied(_:)` it once it has been applied. Anything left in
    /// `processing/` is an action that was drained but never confirmed — see
    /// `recoverUnconfirmed()`.
    public func drain() throws -> [WorkbenchActionRequest] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return []
        }
        let urls = try pendingRequestFileURLs()

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
        guard !sortedRequests.isEmpty else {
            return []
        }
        try FileManager.default.createDirectory(at: processingDirectoryURL, withIntermediateDirectories: true)
        var moved: [WorkbenchActionRequest] = []
        for item in sortedRequests {
            let destination = processingFileURL(for: item.request.id)
            // Replace any stale processing file with the same id before moving.
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: item.url, to: destination)
            moved.append(item.request)
        }
        return moved
    }

    /// Delete the `processing/` file for a request the app has finished
    /// applying. Idempotent: a missing file is a no-op (e.g. already confirmed).
    public func confirmApplied(_ requestId: UUID) {
        let url = processingFileURL(for: requestId)
        try? FileManager.default.removeItem(at: url)
    }

    /// Return (and KEEP) every request still sitting in `processing/` — actions
    /// that a previous `drain()` handed out but that were never confirmed via
    /// `confirmApplied(_:)`, i.e. the app crashed mid-apply. Replaying these on
    /// the next launch turns at-most-once-with-loss into at-least-once. Invalid
    /// files are quarantined to `rejected/` so they can't wedge recovery.
    public func recoverUnconfirmed() -> [WorkbenchActionRequest] {
        guard FileManager.default.fileExists(atPath: processingDirectoryURL.path) else {
            return []
        }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: processingDirectoryURL,
            includingPropertiesForKeys: nil
        ))?
        .filter { $0.pathExtension == "json" } ?? []

        var decoded: [WorkbenchActionRequest] = []
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                decoded.append(try decoder.decode(WorkbenchActionRequest.self, from: data))
            } catch {
                quarantineInvalidRequestFile(url)
            }
        }
        return decoded.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Number of pending request files currently in the queue dir (excludes the
    /// `processing/` and `rejected/` subdirectories). Used by the boss check-in
    /// to detect whether an empty turn nonetheless queued actions before
    /// deciding to retry. Best-effort: returns 0 if the dir can't be listed.
    public func pendingCount() -> Int {
        (try? pendingRequestFileURLs())?.count ?? 0
    }

    /// Whether a request with this id is still in flight — sitting in the queue
    /// dir (drained-not-yet) OR in `processing/` (handed to the app, not yet
    /// confirmed) (#U24). The boss's `workbench_action_result` reads this to tell
    /// a not-yet-applied request (poll again, `queued`) from one the app has
    /// finished and logged. Best-effort: an unreadable dir reads as not-in-flight,
    /// so the action log (the resolved truth) decides instead.
    public func isPendingOrProcessing(requestId: UUID) -> Bool {
        let pending = (try? pendingRequestFileURLs()) ?? []
        let needle = requestId.uuidString
        if pending.contains(where: { $0.lastPathComponent.contains(needle) }) {
            return true
        }
        return FileManager.default.fileExists(atPath: processingFileURL(for: requestId).path)
    }

    /// Top-level pending request files (not the `processing/`, `rejected/`
    /// subdirectories — those have no `.json` extension and the listing is
    /// non-recursive), sorted by filename for a stable order.
    private func pendingRequestFileURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func processingFileURL(for requestId: UUID) -> URL {
        processingDirectoryURL.appendingPathComponent("\(requestId.uuidString).json")
    }

    /// True when a pending request file carries the same action fingerprint as
    /// `request`. Reads the files present in the queue dir at enqueue time;
    /// undecodable files are ignored (they can't be a meaningful duplicate).
    func hasPendingDuplicate(of request: WorkbenchActionRequest) -> Bool {
        let fingerprint = request.fingerprint
        guard let urls = try? pendingRequestFileURLs() else {
            return false
        }
        for url in urls {
            guard
                let data = try? Data(contentsOf: url),
                let existing = try? decoder.decode(WorkbenchActionRequest.self, from: data)
            else {
                continue
            }
            if existing.fingerprint == fingerprint {
                return true
            }
        }
        return false
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
