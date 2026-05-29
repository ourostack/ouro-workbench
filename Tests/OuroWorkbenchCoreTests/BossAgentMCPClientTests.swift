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
        while :; do :; done
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
}
