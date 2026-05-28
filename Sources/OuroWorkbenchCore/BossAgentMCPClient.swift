import Foundation
import Darwin

public enum BossAgentMCPClientError: Error, Equatable, LocalizedError, Sendable {
    case processNotAvailable(String)
    case timeout
    case closed
    case malformedResponse
    case rpcError(String)
    case toolError(String)

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
        }
    }
}

public final class BossAgentMCPClient: @unchecked Sendable {
    public var timeoutNanoseconds: UInt64

    public init(timeoutNanoseconds: UInt64 = 120_000_000_000) {
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    public func ask(agentName: String, question: String) async throws -> String {
        try await callTool(agentName: agentName, name: "ask", arguments: ["question": question])
    }

    public func status(agentName: String) async throws -> String {
        try await callTool(agentName: agentName, name: "status", arguments: [:])
    }

    public func callTool(agentName: String, name: String, arguments: [String: String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ouro", "mcp-serve", "--agent", agentName]
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
        return text
    }

    private func readResponse(_ processBox: ProcessIOBox, id: Int, timeoutNanoseconds: UInt64) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            // Cancel the sibling on every exit path, including the timeout
            // rethrow. (The timeout task also terminates the subprocess so
            // the blocking read unwinds; this keeps the group tidy regardless.)
            defer { group.cancelAll() }
            group.addTask {
                try processBox.readResponse(id: id)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                processBox.terminate()
                throw BossAgentMCPClientError.timeout
            }
            guard let data = try await group.next() else {
                throw BossAgentMCPClientError.closed
            }
            return data
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

    fileprivate static func extractTextIfMatching(line: String, id: Int) throws -> String? {
        let data = Data(line.utf8)
        guard
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            responseID(raw["id"], matches: id)
        else {
            return nil
        }
        return try extractText(fromJSONLine: line)
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

private final class ProcessIOBox: @unchecked Sendable {
    private let process: Process
    private let stdout: FileHandle
    private let stderr: FileHandle

    init(process: Process, stdout: FileHandle, stderr: FileHandle) {
        self.process = process
        self.stdout = stdout
        self.stderr = stderr
    }

    func readResponse(id: Int) throws -> String {
        var buffer = Data()
        while true {
            let chunk = stdout.availableData
            if chunk.isEmpty {
                if !buffer.isEmpty {
                    let line = String(decoding: buffer, as: UTF8.self)
                    if let text = try BossAgentMCPClient.extractTextIfMatching(line: line, id: id) {
                        return text
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
                if let text = try BossAgentMCPClient.extractTextIfMatching(line: line, id: id) {
                    return text
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
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func readStderrText() -> String {
        let data = stderr.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
