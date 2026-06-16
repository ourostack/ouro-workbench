import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class BossAgentMCPClientTests: XCTestCase {
    func testCallToolReturnsWithoutWaitingForLongLivedServerEOF() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OuroWorkbenchMCPClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let mockOuro = temporaryDirectory.appendingPathComponent("ouro")
        let script = """
        #!/bin/sh
        read initialize
        read tool_call
        echo '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"mock status"}],"isError":false}}'
        sleep 300
        """
        try script.write(to: mockOuro, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockOuro.path)

        let oldPath = getenv("PATH").map { String(cString: $0) }
        setenv("PATH", "\(temporaryDirectory.path):\(oldPath ?? "")", 1)
        defer {
            if let oldPath {
                setenv("PATH", oldPath, 1)
            } else {
                unsetenv("PATH")
            }
        }

        let client = BossAgentMCPClient(timeoutNanoseconds: 2_000_000_000)
        let start = Date()

        let text = try await client.status(agentName: "slugger")

        XCTAssertEqual(text, "mock status")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testCallToolSurfacesProcessStderrWhenServerCannotStart() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OuroWorkbenchMCPClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let mockOuro = temporaryDirectory.appendingPathComponent("ouro")
        let script = """
        #!/bin/sh
        echo 'agent bundle slugger is locked' >&2
        exit 1
        """
        try script.write(to: mockOuro, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockOuro.path)

        let oldPath = getenv("PATH").map { String(cString: $0) }
        setenv("PATH", "\(temporaryDirectory.path):\(oldPath ?? "")", 1)
        defer {
            if let oldPath {
                setenv("PATH", oldPath, 1)
            } else {
                unsetenv("PATH")
            }
        }

        let client = BossAgentMCPClient(timeoutNanoseconds: 2_000_000_000)

        do {
            _ = try await client.status(agentName: "slugger")
            XCTFail("Expected status to throw")
        } catch let error as BossAgentMCPClientError {
            XCTAssertEqual(error, .processNotAvailable("agent bundle slugger is locked"))
            XCTAssertEqual(error.localizedDescription, "agent bundle slugger is locked")
        }
    }

    // MARK: - mcp-serve arguments (RUNTIME-INJECTION: pass --workbench-mcp)

    func testMcpServeArgumentsOmitWorkbenchFlagWhenNoPath() {
        XCTAssertEqual(
            BossAgentMCPClient.mcpServeArguments(agentName: "slugger", workbenchMCPPath: nil),
            ["mcp-serve", "--agent", "slugger"]
        )
    }

    func testMcpServeArgumentsAppendWorkbenchFlagWithPath() {
        XCTAssertEqual(
            BossAgentMCPClient.mcpServeArguments(
                agentName: "slugger",
                workbenchMCPPath: "/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP"
            ),
            ["mcp-serve", "--agent", "slugger", "--workbench-mcp", "/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP"]
        )
    }

    func testMcpServeArgumentsAppendWorkbenchFlagPathlessWhenEmpty() {
        XCTAssertEqual(
            BossAgentMCPClient.mcpServeArguments(agentName: "slugger", workbenchMCPPath: ""),
            ["mcp-serve", "--agent", "slugger", "--workbench-mcp"]
        )
    }

    func testClientConfiguredWithPathPassesFlagThroughArgs() {
        let client = BossAgentMCPClient(
            workbenchMCPPath: "/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP"
        )
        XCTAssertEqual(
            client.mcpServeArguments(agentName: "slugger"),
            ["mcp-serve", "--agent", "slugger", "--workbench-mcp", "/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP"]
        )
    }

    func testAskCallsAskToolAndErrorDescriptionsCoverAllCases() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OuroWorkbenchMCPClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let mockOuro = temporaryDirectory.appendingPathComponent("ouro")
        let script = """
        #!/bin/sh
        read initialize
        read tool_call
        echo '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"Ari"}],"isError":false}}'
        """
        try script.write(to: mockOuro, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockOuro.path)
        let oldPath = getenv("PATH").map { String(cString: $0) }
        setenv("PATH", "\(temporaryDirectory.path):\(oldPath ?? "")", 1)
        defer {
            if let oldPath { setenv("PATH", oldPath, 1) } else { unsetenv("PATH") }
        }

        let answer = try await BossAgentMCPClient(timeoutNanoseconds: 2_000_000_000).ask(agentName: "slugger", question: "who")

        XCTAssertEqual(answer, "Ari")
        XCTAssertEqual(BossAgentMCPClientError.processNotAvailable("").errorDescription, "Ouro MCP process is not available.")
        XCTAssertEqual(BossAgentMCPClientError.timeout.errorDescription, "Ouro MCP request timed out.")
        XCTAssertEqual(BossAgentMCPClientError.closed.errorDescription, "Ouro MCP process closed before returning a response.")
        XCTAssertEqual(BossAgentMCPClientError.malformedResponse.errorDescription, "Ouro MCP returned a malformed response.")
        XCTAssertEqual(BossAgentMCPClientError.rpcError("rpc").errorDescription, "rpc")
        XCTAssertEqual(BossAgentMCPClientError.toolError("tool").errorDescription, "tool")
        XCTAssertTrue(BossAgentMCPClientError.emptyResult.localizedDescription.contains("didn't respond"))
    }

    func testExtractsToolTextResponse() throws {
        let line = """
        {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"hello boss"}],"isError":false}}
        """

        let text = try BossAgentMCPClient.extractText(fromJSONLine: line)

        XCTAssertEqual(text, "hello boss")
    }

    func testToolErrorsSurfaceAsErrors() {
        let line = """
        {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"daemon unavailable"}],"isError":true}}
        """

        XCTAssertThrowsError(try BossAgentMCPClient.extractText(fromJSONLine: line)) { error in
            XCTAssertEqual(error as? BossAgentMCPClientError, .toolError("daemon unavailable"))
        }
    }

    func testRPCErrorSurfacesAsError() {
        let line = """
        {"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"nope"}}
        """

        XCTAssertThrowsError(try BossAgentMCPClient.extractText(fromJSONLine: line)) { error in
            XCTAssertEqual(error as? BossAgentMCPClientError, .rpcError("nope"))
        }
    }

    func testEmptyToolTextSurfacesAsEmptyResult() {
        let line = """
        {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"   "}],"isError":false}}
        """
        XCTAssertThrowsError(try BossAgentMCPClient.extractText(fromJSONLine: line)) { error in
            XCTAssertEqual(error as? BossAgentMCPClientError, .emptyResult)
        }
    }

    func testEmptyResponseSentinelSurfacesAsEmptyResult() {
        let line = """
        {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"(empty response)"}],"isError":false}}
        """
        XCTAssertThrowsError(try BossAgentMCPClient.extractText(fromJSONLine: line)) { error in
            XCTAssertEqual(error as? BossAgentMCPClientError, .emptyResult)
        }
    }

    func testNonAnswerDetector() {
        XCTAssertTrue(BossAgentMCPClient.isEmptyOrNonAnswer(""))
        XCTAssertTrue(BossAgentMCPClient.isEmptyOrNonAnswer("  \n "))
        XCTAssertTrue(BossAgentMCPClient.isEmptyOrNonAnswer("(empty response)"))
        XCTAssertTrue(BossAgentMCPClient.isEmptyOrNonAnswer("(No Response)"))
        XCTAssertFalse(BossAgentMCPClient.isEmptyOrNonAnswer("ok"))
        XCTAssertFalse(BossAgentMCPClient.isEmptyOrNonAnswer("(empty response) but here is more"))
    }

    func testExtractsToolResponseFromWholeMCPOutput() throws {
        let output = """
        local boot line
        {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05"}}
        {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"status ok"}],"isError":false}}

        """

        let text = try BossAgentMCPClient.extractText(fromOutput: output, id: 2)

        XCTAssertEqual(text, "status ok")
    }

    func testExtractsStringIDResponseFromWholeMCPOutput() throws {
        let output = """
        {"jsonrpc":"2.0","id":"2","result":{"content":[{"type":"text","text":"string id ok"}],"isError":false}}
        """

        let text = try BossAgentMCPClient.extractText(fromOutput: output, id: 2)

        XCTAssertEqual(text, "string id ok")
    }

    func testMalformedResponsesAreRejected() {
        XCTAssertThrowsError(try BossAgentMCPClient.extractText(fromJSONLine: #"{"jsonrpc":"2.0","id":2}"#)) { error in
            XCTAssertEqual(error as? BossAgentMCPClientError, .malformedResponse)
        }
        XCTAssertThrowsError(try BossAgentMCPClient.extractText(fromOutput: #"{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"wrong"}],"isError":false}}"#, id: 2)) { error in
            XCTAssertEqual(error as? BossAgentMCPClientError, .malformedResponse)
        }
        XCTAssertNil(try BossAgentMCPClient.extractTextIfMatching(line: "not json", id: 2))
        XCTAssertNil(try BossAgentMCPClient.extractTextIfMatching(line: #"{"jsonrpc":"2.0","id":true}"#, id: 2))
        XCTAssertNil(try BossAgentMCPClient.extractTextIfMatching(line: #"{"jsonrpc":"2.0","id":2.5}"#, id: 2))
    }

    func testReadsFinalResponseWithoutTrailingNewline() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OuroWorkbenchMCPClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let mockOuro = temporaryDirectory.appendingPathComponent("ouro")
        let script = """
        #!/bin/sh
        read initialize
        read tool_call
        printf '%s' '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"no newline"}],"isError":false}}'
        """
        try script.write(to: mockOuro, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockOuro.path)
        let oldPath = getenv("PATH").map { String(cString: $0) }
        setenv("PATH", "\(temporaryDirectory.path):\(oldPath ?? "")", 1)
        defer {
            if let oldPath { setenv("PATH", oldPath, 1) } else { unsetenv("PATH") }
        }

        let text = try await BossAgentMCPClient(timeoutNanoseconds: 2_000_000_000).status(agentName: "slugger")

        XCTAssertEqual(text, "no newline")
    }

    func testCallToolTimesOutAndClosesCleanlyWhenServerNeverAnswers() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OuroWorkbenchMCPClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let mockOuro = temporaryDirectory.appendingPathComponent("ouro")
        let script = """
        #!/bin/sh
        read initialize
        read tool_call
        sleep 300
        """
        try script.write(to: mockOuro, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockOuro.path)
        let oldPath = getenv("PATH").map { String(cString: $0) }
        setenv("PATH", "\(temporaryDirectory.path):\(oldPath ?? "")", 1)
        defer {
            if let oldPath { setenv("PATH", oldPath, 1) } else { unsetenv("PATH") }
        }

        do {
            _ = try await BossAgentMCPClient(timeoutNanoseconds: 50_000_000).status(agentName: "slugger")
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? BossAgentMCPClientError, .timeout)
        }
    }

    func testTimeoutForceKillsProcessThatIgnoresTerminate() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OuroWorkbenchMCPClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let mockOuro = temporaryDirectory.appendingPathComponent("ouro")
        let script = """
        #!/bin/sh
        trap '' TERM
        read initialize
        read tool_call
        sleep 300
        """
        try script.write(to: mockOuro, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockOuro.path)
        let oldPath = getenv("PATH").map { String(cString: $0) }
        setenv("PATH", "\(temporaryDirectory.path):\(oldPath ?? "")", 1)
        defer {
            if let oldPath { setenv("PATH", oldPath, 1) } else { unsetenv("PATH") }
        }

        do {
            _ = try await BossAgentMCPClient(timeoutNanoseconds: 20_000_000).status(agentName: "slugger")
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? BossAgentMCPClientError, .timeout)
        }
    }

    func testCallToolReportsClosedWhenServerExitsWithoutResponse() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OuroWorkbenchMCPClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let mockOuro = temporaryDirectory.appendingPathComponent("ouro")
        let script = """
        #!/bin/sh
        read initialize
        read tool_call
        exit 0
        """
        try script.write(to: mockOuro, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockOuro.path)
        let oldPath = getenv("PATH").map { String(cString: $0) }
        setenv("PATH", "\(temporaryDirectory.path):\(oldPath ?? "")", 1)
        defer {
            if let oldPath { setenv("PATH", oldPath, 1) } else { unsetenv("PATH") }
        }

        do {
            _ = try await BossAgentMCPClient(timeoutNanoseconds: 2_000_000_000).status(agentName: "slugger")
            XCTFail("Expected closed")
        } catch {
            XCTAssertEqual(error as? BossAgentMCPClientError, .closed)
        }
    }

    func testTimeoutForceKillsPythonProcessThatIgnoresTerminate() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OuroWorkbenchMCPClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let mockOuro = temporaryDirectory.appendingPathComponent("ouro")
        let script = """
        #!/usr/bin/env python3
        import signal, sys, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        sys.stdin.readline()
        sys.stdin.readline()
        while True:
            time.sleep(0.05)
        """
        try script.write(to: mockOuro, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockOuro.path)
        let oldPath = getenv("PATH").map { String(cString: $0) }
        setenv("PATH", "\(temporaryDirectory.path):\(oldPath ?? "")", 1)
        defer {
            if let oldPath { setenv("PATH", oldPath, 1) } else { unsetenv("PATH") }
        }

        do {
            _ = try await BossAgentMCPClient(timeoutNanoseconds: 20_000_000).status(agentName: "slugger")
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? BossAgentMCPClientError, .timeout)
        }
    }

    // MARK: - retryingOnEmpty

    func testRetryingOnEmptyReturnsFirstSuccessWithoutRetry() async throws {
        let calls = CallRecorder()
        let result = try await BossAgentMCPClient.retryingOnEmpty {
            _ = await calls.increment()
            return "first answer"
        }
        let count = await calls.count
        XCTAssertEqual(result, "first answer")
        XCTAssertEqual(count, 1, "a non-empty first answer must not retry")
    }

    func testRetryingOnEmptyRetriesOnceThenSucceeds() async throws {
        let calls = CallRecorder()
        let result = try await BossAgentMCPClient.retryingOnEmpty {
            let attempt = await calls.increment()
            if attempt == 1 { throw BossAgentMCPClientError.emptyResult }
            return "answer on attempt \(attempt)"
        }
        let count = await calls.count
        XCTAssertEqual(result, "answer on attempt 2")
        XCTAssertEqual(count, 2, "an empty first answer must retry exactly once")
    }

    func testRetryingOnEmptyHonorsRetryVeto() async {
        let calls = CallRecorder()
        do {
            _ = try await BossAgentMCPClient.retryingOnEmpty(canRetry: { false }) {
                _ = await calls.increment()
                throw BossAgentMCPClientError.emptyResult
            }
            XCTFail("Expected emptyResult to propagate when retry is vetoed")
        } catch {
            XCTAssertEqual(error as? BossAgentMCPClientError, .emptyResult)
        }
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }

    func testRetryingOnEmptyRethrowsWhenRetryAlsoEmpty() async {
        let calls = CallRecorder()
        do {
            _ = try await BossAgentMCPClient.retryingOnEmpty {
                _ = await calls.increment()
                throw BossAgentMCPClientError.emptyResult
            }
            XCTFail("Expected emptyResult to propagate when both attempts are empty")
        } catch {
            XCTAssertEqual(error as? BossAgentMCPClientError, .emptyResult)
        }
        let count = await calls.count
        XCTAssertEqual(count, 2, "retry once, then give up (→ backoff)")
    }

    func testRetryingOnEmptyDoesNotRetryNonEmptyError() async {
        let calls = CallRecorder()
        do {
            _ = try await BossAgentMCPClient.retryingOnEmpty {
                _ = await calls.increment()
                throw BossAgentMCPClientError.rpcError("boss is down")
            }
            XCTFail("Expected rpcError to propagate")
        } catch {
            XCTAssertEqual(error as? BossAgentMCPClientError, .rpcError("boss is down"))
        }
        let count = await calls.count
        XCTAssertEqual(count, 1, "real errors must fail straight through, no retry")
    }
}

private actor CallRecorder {
    private(set) var count = 0

    @discardableResult
    func increment() -> Int {
        count += 1
        return count
    }
}
