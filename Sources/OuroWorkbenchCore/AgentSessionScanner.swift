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

    /// Classify a process command line by its leading binary's basename ONLY.
    /// Deliberately dumb and GENERAL: it knows the three harness binary names
    /// (`claude`, `copilot`, `codex`) and nothing else — no agency, no repo, no
    /// agent map. Returns nil for non-agent commands so the boss owns every bit
    /// of context-specific intelligence. Case-sensitive (the binaries are
    /// lowercase) and exact-basename (a name that merely contains an agent word,
    /// like `claude-helper`, does not match).
    public static func classify(command: String) -> AgentHarness? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard let token = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first else {
            return nil
        }
        let binary = String(token).split(separator: "/").last.map(String.init) ?? String(token)
        switch binary {
        case "claude": return .claudeCode
        case "copilot": return .githubCopilotCLI
        case "codex": return .openAICodex
        default: return nil
        }
    }
}

/// One line from a process listing the App/MCP layer supplies. GENERAL: just a
/// pid, the command line, and the working directory if the lister could resolve
/// it. Core never runs `Process` or `ps` itself — the executable target injects
/// the real lister (per the `ProviderVerifyRunner`/`DaemonManager` closure
/// seam), keeping every Core path testable with fakes.
public struct RunningProcessLine: Equatable, Sendable {
    public var pid: Int
    public var command: String
    public var cwd: String?

    public init(pid: Int, command: String, cwd: String? = nil) {
        self.pid = pid
        self.command = command
        self.cwd = cwd
    }

    /// Parse `ps -axww -o pid=,command=` output (one process per line: a
    /// right-aligned pid column, then the full command line) into general
    /// `RunningProcessLine`s. PURE and GENERAL — it knows the `ps` line shape and
    /// nothing about which commands are agents (the scanner's `AgentHarness.classify`
    /// owns that). Lives in Core so the only un-testable part the executable target
    /// carries is the thin `Process` shell that produces this text.
    ///
    /// `cwd` is always nil: `ps` doesn't report a process's working directory, and
    /// the scanner already treats a nil cwd as "unresolved" (→ empty cwd record).
    /// Lines without an integer pid (a header row, garbage) or with no command
    /// after the pid are skipped — nothing to anchor or classify on. Because each
    /// line is whitespace-trimmed first, a pid with no following command has no
    /// internal whitespace boundary and is dropped by the boundary guard, so the
    /// surviving command is always non-empty.
    public static func parsePS(_ output: String) -> [RunningProcessLine] {
        var lines: [RunningProcessLine] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Split off the leading pid token at the first whitespace run; the
            // remainder (verbatim, internal spacing preserved) is the command.
            guard let boundary = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                continue
            }
            let pidToken = String(line[line.startIndex..<boundary])
            guard let pid = Int(pidToken) else { continue }
            let command = String(line[boundary...]).trimmingCharacters(in: .whitespaces)
            lines.append(RunningProcessLine(pid: pid, command: command, cwd: nil))
        }
        return lines
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

    // MARK: - Running discovery

    /// Discover currently-running agent sessions from an INJECTED process lister.
    /// Each line is classified by `AgentHarness.classify`; non-agent lines are
    /// dropped. Records are `running = true` with a stable pid-derived sessionId
    /// (the process table gives no harness session id) and the line's cwd (empty
    /// when the lister couldn't resolve it). No FS, no `Process` here — the App
    /// supplies the real lister.
    public func discoverRunning(processLister: @Sendable () -> [RunningProcessLine]) -> [AgentSessionRecord] {
        processLister().compactMap { line in
            guard let harness = AgentHarness.classify(command: line.command) else { return nil }
            return AgentSessionRecord(
                harness: harness,
                sessionId: "pid-\(line.pid)",
                cwd: line.cwd ?? "",
                repository: nil,
                branch: nil,
                title: nil,
                lastActive: nil,
                running: true
            )
        }
    }

    // MARK: - Unified scan + dedup

    /// Merge recent (Claude + Copilot) with running, dedup, and sort. A running
    /// record beats a recent one for the same logical session (same `id`, OR
    /// same `harness + cwd`). Sort: running-first, then `lastActive` descending
    /// (nil sorts last), then `id` for a deterministic, stable order.
    public func scan(processLister: @Sendable () -> [RunningProcessLine]) -> [AgentSessionRecord] {
        let running = discoverRunning(processLister: processLister)
        let recent = discoverClaudeRecent() + discoverCopilotRecent()
        return Self.merge(running: running, recent: recent)
    }

    /// Pure dedup + sort. Running wins over recent; within a source, a later
    /// `lastActive` wins a `harness + cwd` collision. Sorting is total and stable.
    static func merge(running: [AgentSessionRecord], recent: [AgentSessionRecord]) -> [AgentSessionRecord] {
        var byKey: [String: AgentSessionRecord] = [:]

        func key(for record: AgentSessionRecord) -> String {
            "\(record.harness.rawValue)|\(record.cwd)"
        }

        // Recent first so running can overwrite on collision.
        for record in recent {
            let k = key(for: record)
            if let existing = byKey[k] {
                // Same harness+cwd: keep the more-recent (nil counts as oldest).
                let existingTime = existing.lastActive ?? .distantPast
                let candidateTime = record.lastActive ?? .distantPast
                if candidateTime > existingTime { byKey[k] = record }
            } else {
                byKey[k] = record
            }
        }
        for record in running {
            // Running always wins its harness+cwd slot.
            byKey[key(for: record)] = record
        }

        return byKey.values.sorted { lhs, rhs in
            if lhs.running != rhs.running { return lhs.running }
            let lhsTime = lhs.lastActive ?? .distantPast
            let rhsTime = rhs.lastActive ?? .distantPast
            if lhsTime != rhsTime { return lhsTime > rhsTime }
            return lhs.id < rhs.id
        }
    }
}
