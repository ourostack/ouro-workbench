import Foundation
import Darwin
import OuroWorkbenchCore

@main
struct OuroWorkbenchMCP {
    static func main() {
        WorkbenchMCPServer().run()
    }
}

final class WorkbenchMCPServer {
    private let paths: WorkbenchPaths
    private let store: WorkbenchStore
    private let queue: WorkbenchActionRequestQueue
    private let summarizer = WorkspaceSummarizer()
    private let promptBuilder = BossAgentPromptBuilder()
    private let bootstrapper = WorkbenchBootstrapper()
    private let authorizer = BossWorkbenchActionAuthorizer()
    private let executableHealthChecker = ExecutableHealthChecker()
    private let gitStatusReader = GitStatusReader()
    private let transcriptSearcher = TranscriptSearcher()
    private let recoveryDrill = RecoveryDrill()
    private let senseRenderer = WorkbenchSenseRenderer()

    init(paths: WorkbenchPaths = .defaultPaths()) {
        self.paths = paths
        self.store = WorkbenchStore(paths: paths)
        self.queue = WorkbenchActionRequestQueue(paths: paths)
    }

    func run() {
        while let line = readLine() {
            guard let response = handle(line: line) else {
                continue
            }
            write(response)
        }
    }

    private func handle(line: String) -> [String: Any]? {
        // Blank / whitespace keepalive lines carry no request — skip silently.
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard
            let data = line.data(using: .utf8),
            let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = request["method"] as? String
        else {
            // A non-empty line we can't parse as a JSON-RPC request: reply with
            // a parse error (id null) rather than silently dropping it, so the
            // caller never hangs waiting for a response. (One JSON object per
            // line is the contract — pretty-printed/batched input won't parse.)
            return error(id: nil, code: -32700, message: "Parse error: expected a single JSON-RPC object per line")
        }

        let id = request["id"]
        if id == nil, method.hasPrefix("notifications/") {
            return nil
        }

        do {
            switch method {
            case "initialize":
                return success(id: id, result: [
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": [:]],
                    "serverInfo": [
                        "name": WorkbenchRelease.mcpServerName,
                        "version": WorkbenchRelease.version
                    ]
                ])
            case "tools/list":
                return success(id: id, result: ["tools": toolDefinitions()])
            case "tools/call":
                let text = try callTool(params: request["params"] as? [String: Any] ?? [:])
                return toolResult(id: id, text: text, isError: false)
            default:
                return error(id: id, code: -32601, message: "Unknown method: \(method)")
            }
        } catch {
            return toolResult(id: id, text: error.localizedDescription, isError: true)
        }
    }

    private func callTool(params: [String: Any]) throws -> String {
        guard let name = params["name"] as? String else {
            throw MCPToolFailure("Missing tool name")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        switch name {
        case "workbench_status":
            return try workbenchStatus()
        case "workbench_sense":
            return try workbenchSense()
        case "workbench_transcript_tail":
            return try transcriptTail(arguments: arguments)
        case "workbench_search_transcripts":
            return try searchTranscripts(arguments: arguments)
        case "workbench_recovery_drill":
            return try recoveryDrillReport()
        case "workbench_request_action":
            return try requestAction(arguments: arguments)
        default:
            throw MCPToolFailure("Unknown tool: \(name)")
        }
    }

    private func workbenchStatus() throws -> String {
        let state = try currentState()
        let summary = summarizer.summarize(state)
        let executableHealth = Dictionary(
            uniqueKeysWithValues: state.processEntries.map { entry in
                let executable = ExecutableHealthTarget.executable(for: entry)
                return (entry.id, executableHealthChecker.health(for: executable))
            }
        )
        // Probe git per session (read-only, watchdog-bounded) so the boss's
        // primary read tool reports each session's branch / dirty / ahead-behind.
        let gitStatus = Dictionary(
            uniqueKeysWithValues: state.processEntries.map { entry in
                (entry.id, gitStatusReader.status(forDirectory: entry.workingDirectory))
            }
        )
        return promptBuilder.checkInPrompt(
            question: "What is currently going on in Ouro Workbench?",
            state: state,
            summary: summary,
            executableHealth: executableHealth,
            gitStatus: gitStatus
        )
    }

    private func workbenchSense() throws -> String {
        let state = try currentState()
        return senseRenderer.render(
            state: state,
            summary: summarizer.summarize(state)
        )
    }

    private func transcriptTail(arguments: [String: Any]) throws -> String {
        let state = try currentState()
        let entry = try targetEntry(arguments: arguments, state: state)
        let latestRun = latestRun(for: entry.id, state: state)
        let maxBytes = TranscriptTailLimit.clamped(uintArgument(arguments["maxBytes"]))
        guard let tail = TranscriptTailReader(maxBytes: maxBytes).read(path: latestRun?.transcriptPath) else {
            return "No transcript is available for \(entry.name)."
        }
        let marker = tail.truncated ? "latest \(maxBytes) bytes" : "complete transcript"
        return "\(entry.name) transcript (\(marker)):\n\(tail.text)"
    }

    private func searchTranscripts(arguments: [String: Any]) throws -> String {
        let state = try currentState()
        guard let query = arguments["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPToolFailure("Missing query")
        }
        let maxMatches = Int(TranscriptSearchLimit.clamped(uintArgument(arguments["maxMatches"])))
        let matches = transcriptSearcher.search(query: query, state: state, maxMatches: maxMatches)
        guard !matches.isEmpty else {
            return "No transcript matches for \(query)."
        }
        var lines = ["Transcript matches for \(query):"]
        for match in matches {
            let groupName = groupName(for: match.entryId, state: state) ?? "unknown"
            lines.append("- \(groupName) / \(match.entryName) line \(match.lineNumber) (\(match.transcriptPath)): \(match.line)")
        }
        return lines.joined(separator: "\n")
    }

    private func recoveryDrillReport() throws -> String {
        let state = try currentState()
        let result = recoveryDrill.run(state: state)
        var lines = ["Recovery drill: \(result.oneLineStatus)"]
        for item in result.items {
            let groupName = groupName(for: item.id, state: state) ?? "unknown"
            lines.append("- \(groupName) / \(item.entryName): \(item.beforeStatus?.rawValue ?? "none") -> \(item.afterStatus?.rawValue ?? "none"), action=\(item.action.rawValue), reason=\(item.reason)")
        }
        return lines.joined(separator: "\n")
    }

    private func requestAction(arguments: [String: Any]) throws -> String {
        let state = try currentState()
        guard let rawAction = try optionalString(arguments, key: "action"),
              let actionKind = BossWorkbenchActionKind(rawValue: rawAction) else {
            throw MCPToolFailure("Missing or invalid action")
        }
        let trust: ProcessTrust?
        if let rawTrust = try optionalString(arguments, key: "trust") {
            guard let parsedTrust = ProcessTrust(rawValue: rawTrust) else {
                throw MCPToolFailure("Invalid trust value: \(rawTrust)")
            }
            trust = parsedTrust
        } else {
            trust = nil
        }
        let action = BossWorkbenchAction(
            action: actionKind,
            entry: try optionalString(arguments, key: "entry"),
            text: try optionalString(arguments, key: "text"),
            appendNewline: try optionalBool(arguments, key: "appendNewline") ?? true,
            group: try optionalString(arguments, key: "group"),
            name: try optionalString(arguments, key: "name"),
            command: try optionalString(arguments, key: "command"),
            workingDirectory: try optionalString(arguments, key: "workingDirectory"),
            trust: trust,
            autoResume: try optionalBool(arguments, key: "autoResume")
        )
        try action.validateForQueueing()

        let resolvedEntry: ProcessEntry?
        if let entryValue = action.entry, !entryValue.isEmpty {
            resolvedEntry = try targetEntry(value: entryValue, state: state)
        } else {
            resolvedEntry = nil
        }

        if let entry = resolvedEntry {
            let authorization = authorizer.authorize(action, for: entry)
            guard authorization.isAllowed else {
                throw MCPToolFailure("Action denied for \(entry.name): \(authorization.reason ?? "not authorized")")
            }
        }
        let request = WorkbenchActionRequest(
            source: (arguments["source"] as? String) ?? "ouro-workbench-mcp",
            action: action
        )
        try queue.enqueue(request)
        if let entry = resolvedEntry {
            return "Queued \(actionKind.rawValue) for \(entry.name) as \(request.id.uuidString)."
        }
        return "Queued \(actionKind.rawValue) as \(request.id.uuidString)."
    }

    private func optionalString(_ arguments: [String: Any], key: String) throws -> String? {
        guard let value = arguments[key] else {
            return nil
        }
        guard let string = value as? String else {
            throw MCPToolFailure("\(key) must be a string")
        }
        return string
    }

    private func optionalBool(_ arguments: [String: Any], key: String) throws -> Bool? {
        guard let value = arguments[key] else {
            return nil
        }
        guard let bool = value as? Bool else {
            throw MCPToolFailure("\(key) must be a boolean")
        }
        return bool
    }

    private func currentState() throws -> WorkspaceState {
        // Read-only: never quarantine. The MCP server shares the app's state
        // file but doesn't own it — moving it aside on a transient read or a
        // schema bump (seen by a stale MCP binary) would destroy the app's
        // live workspace. Quarantine is the owning app's decision alone.
        bootstrapper.bootstrappedState(from: try store.load(quarantineCorruptFile: false))
    }

    private func targetEntry(arguments: [String: Any], state: WorkspaceState) throws -> ProcessEntry {
        guard let value = arguments["entry"] as? String, !value.isEmpty else {
            throw MCPToolFailure("Missing entry")
        }
        return try targetEntry(value: value, state: state)
    }

    private func targetEntry(value: String, state: WorkspaceState) throws -> ProcessEntry {
        if let id = UUID(uuidString: value), let entry = state.processEntries.first(where: { $0.id == id }) {
            return entry
        }
        let matches = state.processEntries.filter { $0.name.caseInsensitiveCompare(value) == .orderedSame }
        guard matches.count == 1, let entry = matches.first else {
            throw MCPToolFailure("No unique process entry matches \(value)")
        }
        return entry
    }

    private func latestRun(for entryId: UUID, state: WorkspaceState) -> ProcessRun? {
        state.processRuns
            .filter { $0.entryId == entryId }
            .sorted(by: ProcessRun.isMoreRecent)
            .first
    }

    private func groupName(for entryId: UUID, state: WorkspaceState) -> String? {
        guard let entry = state.processEntries.first(where: { $0.id == entryId }) else {
            return nil
        }
        return state.projects.first { $0.id == entry.projectId }?.name
    }

    private func uintArgument(_ value: Any?) -> UInt64? {
        if let int = value as? Int, int > 0 {
            return UInt64(int)
        }
        if let double = value as? Double, double > 0 {
            guard double.isFinite, double <= Double(UInt64.max) else {
                return UInt64.max
            }
            return UInt64(double)
        }
        return nil
    }

    private func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "workbench_status",
                "description": "Summarize Ouro Workbench state, processes, recovery plans, and transcript paths.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "workbench_sense",
                "description": "Render the Workbench sense contract for the selected Ouro agent: boss/terminal boundaries, available Workbench tools, the ouro-workbench-actions protocol, and the operator keyboard shortcuts (so the boss can answer how-do-I questions).",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "workbench_transcript_tail",
                "description": "Read a bounded tail from the latest transcript for a Workbench process entry.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "entry": ["type": "string", "description": "Process UUID or unique process name."],
                        "maxBytes": [
                            "type": "number",
                            "maximum": Double(TranscriptTailLimit.maximumBytes),
                            "description": "Maximum bytes to read from the end of the transcript. Values above the server cap are clamped."
                        ]
                    ],
                    "required": ["entry"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "workbench_search_transcripts",
                "description": "Search saved Workbench transcript text across process runs.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Case-insensitive text to search for."],
                        "maxMatches": [
                            "type": "number",
                            "maximum": Double(TranscriptSearchLimit.maximumMatches),
                            "description": "Maximum number of matching transcript lines to return. Values above the server cap are clamped."
                        ]
                    ],
                    "required": ["query"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "workbench_recovery_drill",
                "description": "Dry-run restart recovery planning for current Workbench sessions without mutating state.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "workbench_request_action",
                "description": "Queue an auditable Workbench action for the native app to apply to a trusted process entry.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["launch", "recover", "terminate", "sendInput", "createGroup", "createTerminal", "moveSession", "setTrust", "setAutoResume", "archive", "restore"]],
                        "entry": ["type": "string", "description": "Process UUID or unique process name for entry-scoped actions."],
                        "text": ["type": "string", "description": "Required non-empty input text when action is sendInput."],
                        "appendNewline": ["type": "boolean"],
                        "group": ["type": "string", "description": "Group UUID or unique group name for createTerminal and moveSession."],
                        "name": ["type": "string", "description": "Required for createGroup and createTerminal."],
                        "command": ["type": "string", "description": "Required command for createTerminal."],
                        "workingDirectory": ["type": "string", "description": "Group root path or terminal working directory."],
                        "trust": ["type": "string", "enum": ["trusted", "untrusted"]],
                        "autoResume": ["type": "boolean"],
                        "source": ["type": "string", "description": "Agent or tool requesting the action."]
                    ],
                    "required": ["action"],
                    "additionalProperties": false
                ]
            ]
        ]
    }

    private func success(id: Any?, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    private func toolResult(id: Any?, text: String, isError: Bool) -> [String: Any] {
        success(id: id, result: [
            "content": [["type": "text", "text": text]],
            "isError": isError
        ])
    }

    private func error(id: Any?, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": code, "message": message]
        ]
    }

    private func write(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object),
           let text = String(data: data, encoding: .utf8) {
            print(text)
            fflush(stdout)
            return
        }
        // Serialization failed (should never happen for our String/Dict
        // responses, but never hang the caller): emit a minimal, guaranteed
        // valid reply. id is dropped to null since the unserializable value
        // may be the id itself.
        print(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error: response could not be serialized"}}"#)
        fflush(stdout)
    }
}

struct MCPToolFailure: LocalizedError {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
