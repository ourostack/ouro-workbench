import Foundation

/// U30(a) — the durable, per-report outcome that survives the sheet (and the app)
/// closing. Today the filed GitHub-issue URL lives only in a transient `@Published`
/// var and is never written into the bundle, so once the sheet closes neither the
/// operator (re-opening the folder) nor the boss (via a read) can answer "was this
/// bug filed? where?". This record is written as `status.json` next to `report.md`
/// in the bundle, so the answer is on disk and queryable.
public struct BugReportFiledStatus: Codable, Equatable, Sendable {
    /// Whether the report was filed as a GitHub issue (the human-gated venue).
    public var filed: Bool
    /// The filed issue URL, present once `filed` is true.
    public var issueURL: String?
    /// When it was filed (nil while unfiled).
    public var filedAt: Date?
    /// The (already-anonymized at bundle-write time) note the report was created with,
    /// so a folder of reports reads at a glance and the boss read can summarize without
    /// re-opening `report.md`.
    public var note: String
    /// Non-fatal collection warnings recorded at bundle-write time (e.g. screenshot or
    /// diagnostics failed), carried so a partial bundle stays honest after the fact.
    public var collectionWarnings: [String]

    public init(
        filed: Bool,
        issueURL: String?,
        filedAt: Date?,
        note: String,
        collectionWarnings: [String]
    ) {
        self.filed = filed
        self.issueURL = issueURL
        self.filedAt = filedAt
        self.note = note
        self.collectionWarnings = collectionWarnings
    }

    /// The status a freshly-written bundle starts with: saved locally, not yet filed.
    public static func unfiled(note: String, warnings: [String]) -> BugReportFiledStatus {
        BugReportFiledStatus(
            filed: false,
            issueURL: nil,
            filedAt: nil,
            note: note,
            collectionWarnings: warnings
        )
    }

    /// This status with the filed outcome stamped on — called after File-as-Issue
    /// succeeds so the URL is persisted into the bundle, not just held in memory.
    public func markedFiled(issueURL: String, at date: Date) -> BugReportFiledStatus {
        var copy = self
        copy.filed = true
        copy.issueURL = issueURL
        copy.filedAt = date
        return copy
    }
}

/// One bug report as the boss/operator read sees it: the bundle directory + its
/// durable status.
public struct BugReportRecord: Equatable, Sendable {
    public var directoryName: String
    public var directoryURL: URL
    public var status: BugReportFiledStatus

    public init(directoryName: String, directoryURL: URL, status: BugReportFiledStatus) {
        self.directoryName = directoryName
        self.directoryURL = directoryURL
        self.status = status
    }
}

/// Reads and writes the durable `status.json` that lives next to `report.md` in each
/// bug-report bundle, and enumerates recent reports for a boss read. Pure filesystem
/// (every entry point takes an explicit directory), so it's unit-tested against a temp
/// folder rather than the live app-support root.
public struct BugReportStatusStore: Sendable {
    /// The filename the status lives under, inside the bundle directory.
    public static let fileName = "status.json"

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Write (or overwrite) the status file inside `directory`.
    public func write(_ status: BugReportFiledStatus, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(status)
        try data.write(to: directory.appendingPathComponent(Self.fileName), options: [.atomic])
    }

    /// Read the status file inside `directory`, or nil when there is none / it can't be
    /// decoded (an older bundle written before durable status existed has no file).
    public func read(from directory: URL) -> BugReportFiledStatus? {
        let url = directory.appendingPathComponent(Self.fileName)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? decoder.decode(BugReportFiledStatus.self, from: data)
    }

    /// Enumerate the recent bug-report bundles under `folder` (the app's `bug-reports`
    /// directory), newest-first by directory name (the names are sortable timestamps),
    /// each with its durable status. Bundles without a status file are skipped (they
    /// predate durable status). Best-effort: a missing/unreadable folder yields [].
    public func recentReports(inFolder folder: URL, limit: Int = 50) -> [BugReportRecord] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        let directories = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } // newest-first

        var records: [BugReportRecord] = []
        for directory in directories {
            guard let status = read(from: directory) else {
                continue
            }
            records.append(BugReportRecord(
                directoryName: directory.lastPathComponent,
                directoryURL: directory,
                status: status
            ))
            if records.count >= limit {
                break
            }
        }
        return records
    }
}
