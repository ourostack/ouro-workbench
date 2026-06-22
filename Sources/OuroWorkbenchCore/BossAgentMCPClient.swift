import Foundation
import Darwin

public enum BossAgentMCPClientError: Error, Equatable, LocalizedError, Sendable {
    case processNotAvailable(String)
    case timeout
    case closed
    case malformedResponse
    case rpcError(String)
    case toolError(String)
    /// The boss returned a well-formed but empty / non-answer reply. Treated as
    /// a failure (not a blank "success") so a misconfigured boss surfaces an
    /// actionable error instead of an empty pane.
    case emptyResult

    public var errorDescription: String? {
        switch self {
        case .processNotAvailable(let message):
            return message.isEmpty ? "Ouro MCP process is not available." : message
        case .timeout:
            return "Ouro MCP request timed out."
        case .closed:
            return "Ouro MCP process closed before returning a response."
        case .malformedResponse:
            return "Ouro MCP returned a malformed response."
        case .rpcError(let message):
            return message
        case .toolError(let message):
            return message
        case .emptyResult:
            return "Your agent didn't respond. Workbench will try again automatically — if this keeps happening, reopen Workbench."
        }
    }
}

public final class BossAgentMCPClient: @unchecked Sendable {
    public var timeoutNanoseconds: UInt64

    /// The installed Workbench MCP binary path passed to the boss's turn for RUNTIME INJECTION.
    ///
    /// When non-nil, every `mcp-serve` spawn appends `--workbench-mcp <path>` so the `ouro`
    /// runtime injects the Workbench MCP into THIS boss's turn at runtime — nothing is written to
    /// the synced agent bundle. A non-nil but EMPTY string passes the flag path-less so the
    /// `ouro` side self-discovers the binary. `nil` (the default) omits the flag.
    public var workbenchMCPPath: String?

    public init(
        timeoutNanoseconds: UInt64 = 120_000_000_000,
        workbenchMCPPath: String? = nil
    ) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.workbenchMCPPath = workbenchMCPPath
    }

    /// `["mcp-serve", "--agent", <agentName>] (+ ["--workbench-mcp", <path>] | ["--workbench-mcp"])`.
    /// Pure + testable so the spawn site and the bridge plan agree on the exact arg shape.
    public static func mcpServeArguments(agentName: String, workbenchMCPPath: String?) -> [String] {
        ["mcp-serve", "--agent"] + BossAgentBridgePlanner.agentAndWorkbenchArguments(
            agentName: agentName,
            workbenchMCPPath: workbenchMCPPath
        )
    }

    /// The configured spawn args for this client (uses `workbenchMCPPath`).
    public func mcpServeArguments(agentName: String) -> [String] {
        Self.mcpServeArguments(agentName: agentName, workbenchMCPPath: workbenchMCPPath)
    }

    public func ask(agentName: String, question: String) async throws -> String {
        try await callTool(agentName: agentName, name: "ask", arguments: ["question": question])
    }

    public func status(agentName: String) async throws -> String {
        try await callTool(agentName: agentName, name: "status", arguments: [:])
    }

    /// Runs `body`, retrying it exactly once if it throws `.emptyResult` AND the
    /// optional `canRetry` guard permits it.
    ///
    /// Reasoning-model bosses intermittently spend their token budget on
    /// reasoning and emit empty final content; the `ouro` runtime then returns
    /// `(empty response)` and `ask` throws `.emptyResult`. A single fresh retry
    /// almost always yields a real answer, so a transient empty no longer fails
    /// the check-in (and trips backoff). ONLY `.emptyResult` is retried — real
    /// failures (process unavailable, RPC/tool error, timeout, malformed) fall
    /// straight through so a genuinely-down boss still surfaces and backs off.
    ///
    /// `canRetry` lets the caller veto the retry when the first (empty) turn had
    /// observable side effects — e.g. it already enqueued Workbench actions via
    /// the boss's MCP tools. Re-running `body` would queue those actions a second
    /// time, so on a side-effecting empty turn we surface the empty instead of
    /// retrying. Defaults to always-retry to preserve the original behaviour for
    /// callers with no side effects to protect.
    public static func retryingOnEmpty(
        canRetry: @Sendable () -> Bool = { true },
        _ body: sending () async throws -> String
    ) async throws -> String {
        do {
            return try await body()
        } catch BossAgentMCPClientError.emptyResult {
            guard canRetry() else {
                throw BossAgentMCPClientError.emptyResult
            }
            return try await body()
        }
    }

    /// Probe the live boss `mcp-serve` process for the tool names it actually advertises
    /// (#F9). Spawns `ouro` with the IDENTICAL `mcpServeArguments` as `callTool` (so
    /// `--workbench-mcp` is passed the same way), writes `initialize` (id 1) then
    /// `tools/list` (id 2), reads the id-2 line, and parses it via the pure
    /// `WorkbenchToolsInjectionProbe.toolNames` seam. An `alpha.660+` runtime injects the
    /// `workbench_*` catalog into that list; an old runtime returns only boss-native tools
    /// (the silent-strip). Errors/timeouts surface exactly like `callTool` so a hung or
    /// unstartable runtime is observable rather than read as a green empty list.
    public func listToolNames(agentName: String) async throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ouro"] + mcpServeArguments(agentName: agentName)
        process.environment = TerminalEnvironment().valuesWithResolvedPath()

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let processBox = ProcessIOBox(
            process: process,
            stdout: stdout.fileHandleForReading,
            stderr: stderr.fileHandleForReading
        )
        try process.run()

        do {
            try writeLine(initializeRequest(id: 1), to: stdin.fileHandleForWriting)
            try writeLine(Self.toolsListRequest(id: 2), to: stdin.fileHandleForWriting)
            let line = try await readResponseLine(processBox, id: 2, timeoutNanoseconds: timeoutNanoseconds)
            try? stdin.fileHandleForWriting.close()
            await stop(processBox)
            return WorkbenchToolsInjectionProbe.toolNames(fromToolsListJSON: line)
        } catch {
            try? stdin.fileHandleForWriting.close()
            await stop(processBox)
            throw error
        }
    }

    public func callTool(agentName: String, name: String, arguments: [String: String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ouro"] + mcpServeArguments(agentName: agentName)
        process.environment = TerminalEnvironment().valuesWithResolvedPath()

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let processBox = ProcessIOBox(
            process: process,
            stdout: stdout.fileHandleForReading,
            stderr: stderr.fileHandleForReading
        )
        try process.run()

        do {
            try writeLine(
                initializeRequest(id: 1),
                to: stdin.fileHandleForWriting
            )
            try writeLine(
                toolCallRequest(id: 2, name: name, arguments: arguments),
                to: stdin.fileHandleForWriting
            )
            let response = try await readResponse(processBox, id: 2, timeoutNanoseconds: timeoutNanoseconds)
            try? stdin.fileHandleForWriting.close()
            await stop(processBox)
            return response
        } catch {
            try? stdin.fileHandleForWriting.close()
            await stop(processBox)
            throw error
        }
    }

    public static func extractText(fromOutput output: String, id: Int) throws -> String {
        for line in output.split(separator: "\n").map(String.init) {
            if let text = try extractTextIfMatching(line: line, id: id) {
                return text
            }
        }
        throw BossAgentMCPClientError.malformedResponse
    }

    public static func extractText(fromJSONLine line: String) throws -> String {
        let data = Data(line.utf8)
        let response = try JSONDecoder().decode(MCPResponse.self, from: data)
        return try extractText(from: response)
    }

    private static func extractText(from response: MCPResponse) throws -> String {
        if let error = response.error {
            throw BossAgentMCPClientError.rpcError(error.message)
        }
        guard let result = response.result else {
            throw BossAgentMCPClientError.malformedResponse
        }
        let text = result.content.map(\.text).joined(separator: "\n")
        if result.isError {
            throw BossAgentMCPClientError.toolError(text)
        }
        if isEmptyOrNonAnswer(text) {
            throw BossAgentMCPClientError.emptyResult
        }
        return text
    }

    /// True for a blank reply or a known runtime "no answer" sentinel (the
    /// `ouro` runtime emits `(empty response)` when the agent produced nothing).
    static func isEmptyOrNonAnswer(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            return true
        }
        return normalized == "(empty response)"
            || normalized == "(no response)"
            || normalized == "(no output)"
    }

    private func readResponse(_ processBox: ProcessIOBox, id: Int, timeoutNanoseconds: UInt64) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            // Cancel the sibling on every exit path, including the timeout
            // rethrow. The timeout task force-kills the subprocess so the
            // *uncancellable* blocking read always unwinds (EOF on closed stdout)
            // — terminate() alone deadlocks the group when the child ignores SIGTERM.
            defer { group.cancelAll() }
            group.addTask {
                try processBox.readResponse(id: id)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                processBox.terminate()
                processBox.forceKill()
                throw BossAgentMCPClientError.timeout
            }
            return try await firstTaskResult(of: &group, orThrow: BossAgentMCPClientError.closed)
        }
    }

    /// Like `readResponse` but returns the matching id line VERBATIM (no tool-result
    /// decode), for `tools/list` — whose `result.tools` shape the private `MCPResponse`
    /// decoders don't model. The pure seam parses the raw line.
    private func readResponseLine(_ processBox: ProcessIOBox, id: Int, timeoutNanoseconds: UInt64) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                try processBox.readRawLine(id: id)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                processBox.terminate()
                processBox.forceKill()
                throw BossAgentMCPClientError.timeout
            }
            return try await firstTaskResult(of: &group, orThrow: BossAgentMCPClientError.closed)
        }
    }

    private func stop(_ processBox: ProcessIOBox) async {
        processBox.terminate()
        try? await Task.sleep(nanoseconds: 100_000_000)
        processBox.forceKill()
    }

    private func writeLine(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        handle.write(data)
        handle.write(Data([0x0a]))
    }

    private func initializeRequest(id: Int) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": [:],
        ]
    }

    /// The `tools/list` JSON-RPC request — sibling of `toolCallRequest`. Takes no params.
    /// Static + public so the spawn site and the source-pin test agree on the exact body.
    public static func toolsListRequest(id: Int) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/list",
        ]
    }

    private func toolCallRequest(id: Int, name: String, arguments: [String: String]) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": arguments,
            ],
        ]
    }

    static func extractTextIfMatching(line: String, id: Int) throws -> String? {
        let data = Data(line.utf8)
        guard
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            responseID(raw["id"], matches: id)
        else {
            return nil
        }
        return try extractText(fromJSONLine: line)
    }

    /// Returns the line verbatim iff it's a JSON object whose `id` matches — used by the
    /// `tools/list` probe, which keeps the raw line for the pure-seam parse rather than
    /// decoding tool-call content. Non-JSON / id-mismatch ⇒ `nil` (keep scanning).
    static func rawLineIfMatching(line: String, id: Int) -> String? {
        let data = Data(line.utf8)
        guard
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            responseID(raw["id"], matches: id)
        else {
            return nil
        }
        return line
    }

    private static func responseID(_ rawID: Any?, matches expectedID: Int) -> Bool {
        if let id = rawID as? Int {
            return id == expectedID
        }
        if let id = rawID as? String {
            return id == String(expectedID)
        }
        return false
    }
}

private struct MCPResponse: Decodable {
    var result: MCPToolResult?
    var error: MCPError?
}

private struct MCPError: Decodable {
    var message: String
}

private struct MCPToolResult: Decodable {
    var content: [MCPTextContent]
    var isError: Bool
}

private struct MCPTextContent: Decodable {
    var text: String
}

final class ProcessIOBox: @unchecked Sendable {
    private let process: Process
    private let stdout: FileHandle
    private let stderr: FileHandle
    private let processKiller: @Sendable (pid_t, Int32) -> Int32

    init(
        process: Process,
        stdout: FileHandle,
        stderr: FileHandle,
        processKiller: @escaping @Sendable (pid_t, Int32) -> Int32 = { kill($0, $1) }
    ) {
        self.process = process
        self.stdout = stdout
        self.stderr = stderr
        self.processKiller = processKiller
    }

    /// Decode the tool-call text from the matching id line (`tools/call`).
    func readResponse(id: Int) throws -> String {
        try readMatchingLine { line in
            try BossAgentMCPClient.extractTextIfMatching(line: line, id: id)
        }
    }

    /// Return the matching id line VERBATIM (for `tools/list`, whose `result.tools` shape the
    /// tool-call decoders don't model). Same EOF / stderr / closed semantics as `readResponse`.
    func readRawLine(id: Int) throws -> String {
        try readMatchingLine { line in
            BossAgentMCPClient.rawLineIfMatching(line: line, id: id)
        }
    }

    /// Shared line reader: pull stdout chunks, split on newlines, and return the first line for
    /// which `transform` yields non-nil. Handles a final line with no trailing newline at EOF,
    /// surfaces stderr as `.processNotAvailable`, and reports `.closed` on a clean EOF with no
    /// match. Both `readResponse` (decode tool text) and `readRawLine` (keep the line) flow
    /// through here so there's a single read loop.
    private func readMatchingLine(_ transform: (String) throws -> String?) throws -> String {
        var buffer = Data()
        while true {
            let chunk = stdout.availableData
            if chunk.isEmpty {
                if !buffer.isEmpty {
                    let line = String(decoding: buffer, as: UTF8.self)
                    if let matched = try transform(line) {
                        return matched
                    }
                }
                let stderrText = readStderrText()
                if !stderrText.isEmpty {
                    throw BossAgentMCPClientError.processNotAvailable(stderrText)
                }
                throw BossAgentMCPClientError.closed
            }
            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: 0x0a) {
                let lineData = buffer.prefix(upTo: newlineIndex)
                buffer.removeSubrange(...newlineIndex)
                let line = String(decoding: lineData, as: UTF8.self)
                if let matched = try transform(line) {
                    return matched
                }
            }
        }
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    func forceKill() {
        if process.isRunning {
            _ = processKiller(process.processIdentifier, SIGKILL)
        }
    }

    private func readStderrText() -> String {
        let data = stderr.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
