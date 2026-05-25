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
    private let transcriptSearcher = TranscriptSearcher()
    private let recoveryDrill = RecoveryDrill()

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
        guard
            let data = line.data(using: .utf8),
            let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = request["method"] as? String
        else {
            return nil
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
                    "serverInfo": ["name": "ouro-workbench", "version": "0.1.0"]
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
        return promptBuilder.checkInPrompt(
            question: "What is currently going on in Ouro Workbench?",
            state: state,
            summary: summary,
            executableHealth: executableHealth
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
        let entry = try targetEntry(arguments: arguments, state: state)
        guard let rawAction = arguments["action"] as? String, let actionKind = BossWorkbenchActionKind(rawValue: rawAction) else {
            throw MCPToolFailure("Missing or invalid action")
        }
        let action = BossWorkbenchAction(
            action: actionKind,
            entry: entry.id.uuidString,
            text: arguments["text"] as? String,
            appendNewline: (arguments["appendNewline"] as? Bool) ?? true
        )
        try action.validateForQueueing()
        let authorization = authorizer.authorize(action, for: entry)
        guard authorization.isAllowed else {
            throw MCPToolFailure("Action denied for \(entry.name): \(authorization.reason ?? "not authorized")")
        }
        let request = WorkbenchActionRequest(
            source: (arguments["source"] as? String) ?? "ouro-workbench-mcp",
            action: action
        )
        try queue.enqueue(request)
        return "Queued \(actionKind.rawValue) for \(entry.name) as \(request.id.uuidString)."
    }

    private func currentState() throws -> WorkspaceState {
        bootstrapper.bootstrappedState(from: try store.load())
    }

    private func targetEntry(arguments: [String: Any], state: WorkspaceState) throws -> ProcessEntry {
        guard let value = arguments["entry"] as? String, !value.isEmpty else {
            throw MCPToolFailure("Missing entry")
        }
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
            .sorted { $0.startedAt > $1.startedAt }
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
                        "action": ["type": "string", "enum": ["launch", "recover", "terminate", "sendInput"]],
                        "entry": ["type": "string", "description": "Process UUID or unique process name."],
                        "text": ["type": "string", "description": "Required non-empty input text when action is sendInput."],
                        "appendNewline": ["type": "boolean"],
                        "source": ["type": "string", "description": "Agent or tool requesting the action."]
                    ],
                    "required": ["action", "entry"],
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
        guard
            let data = try? JSONSerialization.data(withJSONObject: object),
            let text = String(data: data, encoding: .utf8)
        else {
            return
        }
        print(text)
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
