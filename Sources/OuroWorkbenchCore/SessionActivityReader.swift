import Foundation

/// Locates and tails a session's structured JSONL transcript and distills it
/// into a `SessionActivity`. Read-only and bounded: it seeks to the END of the
/// file and reads at most `maxBytes` (transcripts reach 100+ MB and single
/// lines reach 100s of KB when a tool_result embeds a file), so cost is capped
/// regardless of file size — the same posture as `GitStatusReader`'s watchdog.
///
/// Mapping a session → JSONL is *forward-derived*, never reverse-decoded:
/// Claude Code names a project dir by replacing every `/` and `.` in the
/// working directory with `-` (e.g. `/Users/a/Projects/x/.claude/worktrees/y`
/// → `-Users-a-Projects-x--claude-worktrees-y`). That transform is lossy
/// (real path segments contain `-`), so we encode the *known* working
/// directory and look the dir up — we never try to decode a dir name back to a
/// path. Within the dir (which can hold several session files) we pick the
/// most-recently-modified `.jsonl`. No dir / no file → `nil`, and the chip
/// falls back to its free facets.
public struct SessionActivityReader: Sendable {
    public var homeURL: URL
    /// Bytes read from the tail of each transcript. ~256 KB ≈ ~130 records at
    /// the observed ~1.9 KB/line average — enough to capture the latest todo
    /// snapshot, recent tool activity, and a recent token window.
    public var maxBytes: UInt64

    /// `FileManager.default` is a process-wide singleton; not stored (it is
    /// non-Sendable) but referenced directly in methods, matching
    /// `GitStatusReader`.
    private var fileManager: FileManager { .default }

    public init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        maxBytes: UInt64 = 256_000
    ) {
        self.homeURL = homeURL
        self.maxBytes = maxBytes
    }

    /// Derive activity for a session from its working directory + agent kind.
    /// Returns nil when no transcript maps to the session (e.g. a plain human
    /// shell), the file can't be read, or nothing useful is in the tail.
    public func activity(forDirectory directory: String, agentKind: TerminalAgentKind?) -> SessionActivity? {
        guard !directory.isEmpty else { return nil }
        switch agentKind {
        case .openAICodex:
            guard let url = codexTranscriptURL(forDirectory: directory),
                  let tail = tailText(of: url) else { return nil }
            let activity = SessionActivity.parse(codexJSONLTail: tail)
            return activity.isEmpty ? nil : activity
        case .claudeCode, .githubCopilotCLI, .custom, .none:
            // Copilot/custom may still be Claude-shaped (most non-Codex CLIs on
            // this surface write the Claude projects layout); try Claude first.
            guard let url = claudeTranscriptURL(forDirectory: directory),
                  let tail = tailText(of: url) else { return nil }
            let activity = SessionActivity.parse(claudeJSONLTail: tail)
            return activity.isEmpty ? nil : activity
        }
    }

    // MARK: - Session → JSONL mapping

    /// `~/.claude/projects/<encoded-dir>/` for a working directory, picking the
    /// most-recently-modified `.jsonl` inside it. nil when the dir or no file
    /// exists.
    func claudeTranscriptURL(forDirectory directory: String) -> URL? {
        let encoded = Self.claudeProjectDirName(forDirectory: directory)
        let projectDir = homeURL
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
        return mostRecentJSONL(in: projectDir)
    }

    /// Claude Code's project-dir encoding: every `/` and `.` → `-`.
    public static func claudeProjectDirName(forDirectory directory: String) -> String {
        String(directory.map { ($0 == "/" || $0 == ".") ? "-" : $0 })
    }

    /// Codex rollout files live flat under `~/.codex/sessions/<Y>/<M>/<D>/` and
    /// record their `cwd` in a `session_meta` line rather than in the path, so
    /// the dir can't be derived from the cwd. We scan recent rollout files and
    /// match on the `cwd` recorded in each file's head. Bounded: only the most
    /// recent files are considered, and each is probed by reading just its head.
    func codexTranscriptURL(forDirectory directory: String) -> URL? {
        let sessionsRoot = homeURL.appendingPathComponent(".codex/sessions", isDirectory: true)
        let candidates = recentFiles(under: sessionsRoot, pathExtension: "jsonl", limit: 40)
        for url in candidates where codexHeadCwd(of: url) == directory {
            return url
        }
        return nil
    }

    /// The `cwd` recorded in a Codex rollout's `session_meta` line, read from
    /// the file head only (the meta line is near the top).
    private func codexHeadCwd(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16_000)) ?? Data()
        for line in String(decoding: head, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let payload = object["payload"] as? [String: Any], let cwd = payload["cwd"] as? String {
                return cwd
            }
            if let cwd = object["cwd"] as? String { return cwd }
        }
        return nil
    }

    private func mostRecentJSONL(in directory: URL) -> URL? {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return entries
            .filter { $0.pathExtension == "jsonl" }
            .max { modificationDate($0) < modificationDate($1) }
    }

    func recentFiles(
        under root: URL,
        pathExtension: String,
        limit: Int,
        makeEnumerator: (URL) -> FileManager.DirectoryEnumerator? = {
            FileManager.default.enumerator(
                at: $0,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
        }
    ) -> [URL] {
        guard let enumerator = makeEnumerator(root) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == pathExtension {
            urls.append(url)
        }
        return Array(urls.sorted { modificationDate($0) > modificationDate($1) }.prefix(limit))
    }

    func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    // MARK: - Bounded tail read

    /// Read at most `maxBytes` from the END of the file as UTF-8 text. Mirrors
    /// `TranscriptTailReader`'s seek-to-end approach so a huge transcript can't
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
}

// MARK: - Parsing (pure, unit-tested)

extension SessionActivity {
    /// Parse a tail of Claude Code JSONL into a `SessionActivity`.
    ///
    /// Schema (grounded against real `~/.claude/projects/*.jsonl` files):
    /// - One JSON object per line; `type` is `assistant` | `user` | …
    /// - Assistant: `message.content[]` blocks of `tool_use` / `text` /
    ///   `thinking`; `message.usage` carries `{input_tokens, output_tokens,
    ///   cache_read_input_tokens, cache_creation_input_tokens}`; `message.model`
    ///   is the model id; `message.id` groups the lines of one logical message.
    /// - Todo progress comes from the LATEST `TodoWrite` tool_use, whose
    ///   `input.todos[]` each carry `{content, status, activeForm}` with status
    ///   ∈ {completed, in_progress, pending}. Each TodoWrite is a *full
    ///   snapshot*, so the last one alone gives complete progress.
    ///
    /// CRUCIAL: a single assistant message is split across multiple JSONL lines
    /// (one per content block), and every such line repeats the SAME `usage`.
    /// Summing naively double-counts (observed ~4974 lines → ~3414 messages),
    /// so usage is de-duplicated by `message.id` (lines without an id are
    /// counted once each, since they can't be grouped).
    ///
    /// REDACTION: only tool *names* + a single short path/identifier token are
    /// pulled from tool_use inputs — never the full input. tool_result content
    /// (which embeds file contents/secrets) is ignored entirely.
    public static func parse(claudeJSONLTail tail: String) -> SessionActivity {
        var latestTodos: [[String: Any]]?
        var lastTool: String?
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheCreationTokens = 0
        var countedMessageIDs = Set<String>()
        var modelCounts: [String: Int] = [:]

        for rawLine in tail.split(whereSeparator: \.isNewline) {
            // The first line of a byte-bounded tail is usually a partial line;
            // JSONSerialization simply fails on it and we skip — no special case
            // needed. Malformed lines are skipped the same way.
            guard let data = String(rawLine).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["type"] as? String) == "assistant",
                  let message = object["message"] as? [String: Any]
            else { continue }

            if let model = message["model"] as? String, model != "<synthetic>" {
                modelCounts[model, default: 0] += 1
            }

            // Usage — de-duped by message id.
            if let usage = message["usage"] as? [String: Any] {
                let id = message["id"] as? String
                let alreadyCounted = id.map { countedMessageIDs.contains($0) } ?? false
                if !alreadyCounted {
                    if let id { countedMessageIDs.insert(id) }
                    inputTokens += intValue(usage["input_tokens"])
                    outputTokens += intValue(usage["output_tokens"])
                    cacheReadTokens += intValue(usage["cache_read_input_tokens"])
                    cacheCreationTokens += intValue(usage["cache_creation_input_tokens"])
                }
            }

            // Tool use + latest todo snapshot.
            guard let content = message["content"] as? [[String: Any]] else { continue }
            for block in content where (block["type"] as? String) == "tool_use" {
                guard let name = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any]
                if name == "TodoWrite", let todos = input?["todos"] as? [[String: Any]] {
                    latestTodos = todos
                }
                lastTool = redactedToolLabel(name: name, input: input)
            }
        }

        var todoDone = 0
        var todoTotal = 0
        var activeForm: String?
        if let todos = latestTodos {
            todoTotal = todos.count
            for todo in todos {
                let status = (todo["status"] as? String) ?? ""
                if status == "completed" { todoDone += 1 }
                if status == "in_progress", activeForm == nil {
                    activeForm = (todo["activeForm"] as? String) ?? (todo["content"] as? String)
                }
            }
        }

        let model = modelCounts.max { $0.value < $1.value }?.key

        return SessionActivity(
            todoDone: todoDone,
            todoTotal: todoTotal,
            activeForm: activeForm.flatMap(nonEmpty),
            lastToolActivity: lastTool.flatMap(nonEmpty),
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            model: model
        )
    }

    /// Parse a tail of Codex rollout JSONL. Codex's schema is entirely
    /// different from Claude's (grounded on real `~/.codex/sessions/**.jsonl`):
    /// - `type` ∈ {`response_item`, `event_msg`, `turn_context`, `session_meta`}
    /// - Token usage rides `event_msg` payloads of type `token_count`, whose
    ///   `info.total_token_usage` is a running CUMULATIVE total — so we take the
    ///   LAST one rather than summing.
    /// - Tool activity: `event_msg` payloads `exec_command_end` /
    ///   `patch_apply_end` / `mcp_tool_call_end`.
    /// Codex transcripts carry no TodoWrite-equivalent, so todo progress is
    /// absent (the chip shows tokens + last-activity only for Codex).
    public static func parse(codexJSONLTail tail: String) -> SessionActivity {
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var lastTool: String?

        for rawLine in tail.split(whereSeparator: \.isNewline) {
            guard let data = String(rawLine).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["type"] as? String) == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String
            else { continue }

            switch payloadType {
            case "token_count":
                if let info = payload["info"] as? [String: Any],
                   let total = info["total_token_usage"] as? [String: Any] {
                    // Cumulative — overwrite rather than add.
                    inputTokens = intValue(total["input_tokens"])
                    outputTokens = intValue(total["output_tokens"])
                    cacheReadTokens = intValue(total["cached_input_tokens"])
                }
            case "exec_command_end":
                lastTool = "Run command"
            case "patch_apply_end":
                lastTool = "Apply patch"
            case "mcp_tool_call_end":
                lastTool = "MCP tool"
            case "web_search_end":
                lastTool = "Web search"
            default:
                break
            }
        }

        // Codex's cumulative input_tokens already include cached input; subtract
        // so the priced "input" is the non-cached remainder (cache is priced
        // separately and far cheaper).
        let nonCachedInput = max(0, inputTokens - cacheReadTokens)

        return SessionActivity(
            todoDone: 0,
            todoTotal: 0,
            activeForm: nil,
            lastToolActivity: lastTool.flatMap(nonEmpty),
            inputTokens: nonCachedInput,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: 0,
            model: "gpt-5"
        )
    }

    /// A redacted one-line label for a tool use: the tool name plus at most one
    /// short, non-sensitive identifier (a file's basename, or the first token of
    /// a Bash command). Never the full input. MCP tool names are shortened to
    /// their trailing segment.
    static func redactedToolLabel(name: String, input: [String: Any]?) -> String {
        let displayName = shortToolName(name)
        guard let input else { return displayName }

        // File-path tools: show the basename only.
        for key in ["file_path", "path", "notebook_path"] {
            if let value = input[key] as? String, !value.isEmpty {
                return "\(displayName) \(URL(fileURLWithPath: value).lastPathComponent)"
            }
        }
        // Bash: show only the leading command word (e.g. "git"), never args —
        // args routinely contain secrets, tokens, and full file contents.
        if name == "Bash", let command = input["command"] as? String {
            let head = command
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0 == " " || $0 == "\n" })
                .first
            if let head, !head.isEmpty {
                return "\(displayName) \(head)"
            }
        }
        // Task / agent tools: a short subject is safe and useful.
        for key in ["subject", "description"] {
            if let value = input[key] as? String, !value.isEmpty {
                return "\(displayName): \(truncate(value, to: 32))"
            }
        }
        return displayName
    }

    /// Shorten `mcp__server__tool` to `tool`; leave plain tool names as-is.
    static func shortToolName(_ name: String) -> String {
        if name.hasPrefix("mcp__"), let last = name.split(separator: "_").last {
            return String(last)
        }
        return name
    }

    static func intValue(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let n = value as? NSNumber { return n.intValue }
        return 0
    }

    static func nonEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func truncate(_ s: String, to max: Int) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= max { return trimmed }
        return String(trimmed.prefix(max - 1)) + "…"
    }
}
