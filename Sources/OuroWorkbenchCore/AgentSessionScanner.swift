import Foundation

/// The agent harness that produced a discovered session. GENERAL by design —
/// it names only the harness binary family, never an agent identity, a repo, or
/// any MS/agency-specific knowledge. Mirrors `TerminalAgentKind` (and decodes
/// unknown raw values to `.custom` the same way) so a record can flow into a
/// `ProcessEntry`/`CustomTerminalSessionDraft` without a lossy remap.
public enum AgentHarness: String, Codable, CaseIterable, Sendable {
    case claudeCode
    case githubCopilotCLI
    case openAICodex
    case custom

    /// Unknown raw values (a harness added by a newer build, or a future Codable
    /// of an extended enum) decode to `.custom` rather than throwing — a record
    /// from a newer producer is still usable, just defaulted.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentHarness(rawValue: raw) ?? .custom
    }
}

/// A GENERAL record of a discovered agent session. Zero command-building, zero
/// agency knowledge: it states only what was observed on disk or in the process
/// table. The boss agent — not Workbench — turns these facts into resume
/// commands. Fields are exactly the discovery surface the spec locked:
/// `harness, sessionId, cwd, repository, branch, title, lastActive, running`.
public struct AgentSessionRecord: Codable, Equatable, Sendable {
    public var harness: AgentHarness
    public var sessionId: String
    public var cwd: String
    public var repository: String?
    public var branch: String?
    public var title: String?
    public var lastActive: Date?
    public var running: Bool

    /// Stable identity: harness + sessionId. Two scans of the same session
    /// produce the same `id`, which is what dedup keys on.
    public var id: String { "\(harness.rawValue):\(sessionId)" }

    public init(
        harness: AgentHarness,
        sessionId: String,
        cwd: String,
        repository: String? = nil,
        branch: String? = nil,
        title: String? = nil,
        lastActive: Date? = nil,
        running: Bool
    ) {
        self.harness = harness
        self.sessionId = sessionId
        self.cwd = cwd
        self.repository = repository
        self.branch = branch
        self.title = title
        self.lastActive = lastActive
        self.running = running
    }

    private enum CodingKeys: String, CodingKey {
        case harness
        case sessionId
        case cwd
        case repository
        case branch
        case title
        case lastActive
        case running
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.harness = try container.decode(AgentHarness.self, forKey: .harness)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.cwd = try container.decode(String.self, forKey: .cwd)
        self.repository = try container.decodeIfPresent(String.self, forKey: .repository)
        self.branch = try container.decodeIfPresent(String.self, forKey: .branch)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.lastActive = try container.decodeIfPresent(Date.self, forKey: .lastActive)
        self.running = try container.decode(Bool.self, forKey: .running)
    }
}

/// Discovers agent sessions the boss did NOT create — recent (on disk) and
/// running (in the process table) — and emits GENERAL `AgentSessionRecord`s.
/// It states facts only: it never builds a resume command and carries no
/// agency/repo/agent-map knowledge — the boss turns these records into actions.
///
/// A CLEAN SIBLING of the rejected `RecentSessionScanner`; it shares none of its
/// code. FS access goes through the injected `homeURL` seam (per
/// `SessionActivityReader`) so every path is testable against a temp dir.
public struct AgentSessionScanner: Sendable {
    public var homeURL: URL
    /// Bytes read from the tail of each Claude transcript. The discovery keys
    /// (`cwd/gitBranch/sessionId/timestamp/aiTitle`) repeat on most lines and we
    /// want the LATEST timestamp/title, so a bounded tail is enough and caps
    /// cost on 100+ MB transcripts — same posture as `SessionActivityReader`.
    public var maxBytes: UInt64

    private var fileManager: FileManager { .default }

    public init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        maxBytes: UInt64 = 256_000
    ) {
        self.homeURL = homeURL
        self.maxBytes = maxBytes
    }

    // MARK: - ISO8601

    /// Parse an ISO8601 timestamp, trying fractional seconds first then plain
    /// (Claude/Copilot both stamp `...Z` with milliseconds). nil on garbage or
    /// nil input — a bad timestamp simply leaves `lastActive` unset.
    public static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    // MARK: - Claude recent

    /// Discover recent Claude Code sessions under `~/.claude/projects/<dir>/*.jsonl`.
    /// Each file → at most one record, extracted from the TOP-LEVEL per-line keys
    /// (`cwd/gitBranch/sessionId/timestamp/aiTitle|summary`) — grounded against
    /// real files; these are NOT under `message`. `running = false`.
    public func discoverClaudeRecent() -> [AgentSessionRecord] {
        let projectsDir = homeURL.appendingPathComponent(".claude/projects", isDirectory: true)
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var records: [AgentSessionRecord] = []
        for projectDir in projectDirs {
            guard let files = try? fileManager.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let tail = tailText(of: file) else { continue }
                let fallbackId = file.deletingPathExtension().lastPathComponent
                if let record = Self.parseClaudeRecord(tail: tail, fallbackSessionId: fallbackId) {
                    records.append(record)
                }
            }
        }
        return records
    }

    /// Pure: distill a Claude JSONL tail into a record. Returns nil when no line
    /// carries a `cwd` (nothing to anchor on). Takes the LATEST values seen for
    /// timestamp/title; sessionId prefers the in-record value, else the filename
    /// stem. Malformed/partial lines (the first tail line is usually partial) are
    /// skipped by JSON-parse failure — same tolerance as `SessionActivity.parse`.
    static func parseClaudeRecord(tail: String, fallbackSessionId: String) -> AgentSessionRecord? {
        var cwd: String?
        var branch: String?
        var sessionId: String?
        var title: String?
        var lastActive: Date?

        for rawLine in tail.split(whereSeparator: \.isNewline) {
            guard let data = String(rawLine).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let value = object["cwd"] as? String, !value.isEmpty { cwd = value }
            if let value = object["gitBranch"] as? String, !value.isEmpty { branch = value }
            if let value = object["sessionId"] as? String, !value.isEmpty { sessionId = value }
            if let value = (object["aiTitle"] as? String) ?? (object["summary"] as? String), !value.isEmpty {
                title = value
            }
            if let value = object["timestamp"] as? String, let date = parseISO8601(value) {
                lastActive = date
            }
        }

        guard let cwd else { return nil }
        return AgentSessionRecord(
            harness: .claudeCode,
            sessionId: sessionId ?? fallbackSessionId,
            cwd: cwd,
            repository: nil,
            branch: branch,
            title: title,
            lastActive: lastActive,
            running: false
        )
    }

    // MARK: - Copilot recent

    /// Discover recent Copilot CLI sessions under
    /// `~/.copilot/session-state/<id>/workspace.yaml`. Flat key:value (parsed by
    /// `FlatYAMLReader`): `id, cwd, repository, branch, name, created_at,
    /// updated_at`. `running = false`.
    public func discoverCopilotRecent() -> [AgentSessionRecord] {
        let stateDir = homeURL.appendingPathComponent(".copilot/session-state", isDirectory: true)
        guard let sessionDirs = try? fileManager.contentsOfDirectory(
            at: stateDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var records: [AgentSessionRecord] = []
        for sessionDir in sessionDirs {
            let yaml = sessionDir.appendingPathComponent("workspace.yaml")
            guard let text = try? String(contentsOf: yaml, encoding: .utf8) else { continue }
            let fallbackId = sessionDir.lastPathComponent
            if let record = Self.parseCopilotRecord(yaml: text, fallbackSessionId: fallbackId) {
                records.append(record)
            }
        }
        return records
    }

    /// Pure: distill a Copilot `workspace.yaml` body into a record. Returns nil
    /// when there is no `cwd`. `updated_at` wins over `created_at` for
    /// `lastActive`; sessionId prefers the in-file `id`, else the dir name.
    static func parseCopilotRecord(yaml: String, fallbackSessionId: String) -> AgentSessionRecord? {
        let fields = FlatYAMLReader.parse(yaml)
        guard let cwd = fields["cwd"], !cwd.isEmpty else { return nil }
        let lastActive = parseISO8601(fields["updated_at"]) ?? parseISO8601(fields["created_at"])
        return AgentSessionRecord(
            harness: .githubCopilotCLI,
            sessionId: nonEmpty(fields["id"]) ?? fallbackSessionId,
            cwd: cwd,
            repository: nonEmpty(fields["repository"]),
            branch: nonEmpty(fields["branch"]),
            title: nonEmpty(fields["name"]),
            lastActive: lastActive,
            running: false
        )
    }

    // MARK: - Bounded tail read

    /// Read at most `maxBytes` from the END of a file as UTF-8 — same seek-to-end
    /// posture as `SessionActivityReader.tailText` so a huge transcript can't
    /// wedge the read.
    func tailText(of url: URL) -> String? {
        guard maxBytes > 0, fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            let offset = size > maxBytes ? size - maxBytes : 0
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    /// Trim + nil-if-empty, so blank YAML values become `nil` rather than `""`.
    static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
