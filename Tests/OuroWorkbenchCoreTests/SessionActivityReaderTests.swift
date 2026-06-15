import XCTest
@testable import OuroWorkbenchCore

final class SessionActivityReaderTests: XCTestCase {
    func testClaudeProjectDirectoryEncodingReplacesSlashesAndDotsOnly() {
        XCTAssertEqual(
            SessionActivityReader.claudeProjectDirName(forDirectory: "/Users/me/project.with.dots"),
            "-Users-me-project-with-dots"
        )
    }

    func testActivityReturnsNilForEmptyDirectoryMissingTranscriptAndEmptyTail() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = SessionActivityReader(homeURL: home, maxBytes: 1_000)

        XCTAssertNil(reader.activity(forDirectory: "", agentKind: .claudeCode))
        XCTAssertNil(reader.activity(forDirectory: "/missing", agentKind: .claudeCode))

        let transcript = try writeClaudeTranscript(home: home, directory: "/empty", name: "empty.jsonl", contents: #"{"type":"user"}"#)
        XCTAssertEqual(reader.claudeTranscriptURL(forDirectory: "/empty")?.standardizedFileURL, transcript.standardizedFileURL)
        XCTAssertNil(reader.activity(forDirectory: "/empty", agentKind: .claudeCode))
    }

    func testClaudeActivityUsesMostRecentTranscriptAndParsesTodosTokensAndRedactedTool() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let old = try writeClaudeTranscript(home: home, directory: "/repo", name: "old.jsonl", contents: #"{"type":"assistant","message":{"id":"old","model":"claude","content":[{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}"#)
        let transcript = try writeClaudeTranscript(home: home, directory: "/repo", name: "new.jsonl", contents: """
        not-json
        {"type":"assistant","message":{"id":"m1","model":"claude-sonnet","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":5},"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"Done","status":"completed"},{"content":"Ship it","status":"in_progress","activeForm":"Shipping coverage"}]}}]}}
        {"type":"assistant","message":{"id":"m1","model":"claude-sonnet","usage":{"input_tokens":100,"output_tokens":20},"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/repo/Sources/OuroWorkbenchCore/SessionActivityReader.swift"}}]}}
        """)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: transcript.path)
        let reader = SessionActivityReader(homeURL: home, maxBytes: 10_000)

        let activity = try XCTUnwrap(reader.activity(forDirectory: "/repo", agentKind: .claudeCode))

        XCTAssertEqual(activity.todoDone, 1)
        XCTAssertEqual(activity.todoTotal, 2)
        XCTAssertEqual(activity.activeForm, "Shipping coverage")
        XCTAssertEqual(activity.lastToolActivity, "Read SessionActivityReader.swift")
        XCTAssertEqual(activity.inputTokens, 100)
        XCTAssertEqual(activity.outputTokens, 20)
        XCTAssertEqual(activity.cacheReadTokens, 30)
        XCTAssertEqual(activity.cacheCreationTokens, 5)
        XCTAssertEqual(activity.model, "claude-sonnet")
    }

    func testClaudeParserCoversRedactionFallbacksAndNumericTokenShapes() {
        let longDescription = String(repeating: "a", count: 40)
        let tail = """
        {"type":"assistant","message":{"id":"m1","model":"<synthetic>","usage":{"input_tokens":12.8,"output_tokens":7,"cache_read_input_tokens":2,"cache_creation_input_tokens":1},"content":[{"type":"tool_use","name":"mcp__server__search","input":{"subject":"\(longDescription)"}}]}}
        {"type":"assistant","message":{"usage":{"input_tokens":3,"output_tokens":4},"content":[{"type":"tool_use","name":"NotebookRead","input":{"notebook_path":"/repo/Analysis.ipynb"}}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","input":{}}]}}
        """

        let activity = SessionActivity.parse(claudeJSONLTail: tail)

        XCTAssertEqual(activity.inputTokens, 15)
        XCTAssertEqual(activity.outputTokens, 11)
        XCTAssertEqual(activity.cacheReadTokens, 2)
        XCTAssertEqual(activity.cacheCreationTokens, 1)
        XCTAssertEqual(activity.lastToolActivity, "NotebookRead Analysis.ipynb")
        XCTAssertNil(activity.model)
        XCTAssertEqual(SessionActivity.redactedToolLabel(name: "Task", input: ["description": "  \(longDescription)  "]), "Task: \(String(repeating: "a", count: 31))…")
        XCTAssertEqual(SessionActivity.redactedToolLabel(name: "Bash", input: ["command": "  \n  "]), "Bash")
        XCTAssertEqual(SessionActivity.redactedToolLabel(name: "Bash", input: nil), "Bash")
    }

    func testCodexActivityScansRecentFilesByHeadCwdAndUsesCumulativeTokenCounts() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try writeCodexTranscript(home: home, relative: "2026/06/14/old.jsonl", contents: #"{"cwd":"/other"}"#)
        _ = try writeCodexTranscript(home: home, relative: "2026/06/15/match.jsonl", contents: """
        {"type":"session_meta","payload":{"cwd":"/repo"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10,"cached_input_tokens":40}}}}
        {"type":"event_msg","payload":{"type":"exec_command_end"}}
        {"type":"event_msg","payload":{"type":"patch_apply_end"}}
        {"type":"event_msg","payload":{"type":"mcp_tool_call_end"}}
        {"type":"event_msg","payload":{"type":"web_search_end"}}
        {"type":"event_msg","payload":{"type":"unknown"}}
        """)
        let reader = SessionActivityReader(homeURL: home, maxBytes: 10_000)

        let activity = try XCTUnwrap(reader.activity(forDirectory: "/repo", agentKind: .openAICodex))

        XCTAssertEqual(activity.inputTokens, 60)
        XCTAssertEqual(activity.outputTokens, 10)
        XCTAssertEqual(activity.cacheReadTokens, 40)
        XCTAssertEqual(activity.lastToolActivity, "Web search")
        XCTAssertEqual(activity.model, "gpt-5")
    }

    func testCodexHeadSupportsTopLevelCwdAndTailReaderBoundsBytes() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try writeCodexTranscript(home: home, relative: "2026/06/15/match.jsonl", contents: """
        {"cwd":"/repo"}
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":2,"cached_input_tokens":50}}}}
        """)
        let zeroReader = SessionActivityReader(homeURL: home, maxBytes: 0)
        XCTAssertNil(zeroReader.activity(forDirectory: "/repo", agentKind: .openAICodex))

        let reader = SessionActivityReader(homeURL: home, maxBytes: 10_000)
        let activity = try XCTUnwrap(reader.activity(forDirectory: "/repo", agentKind: .openAICodex))
        XCTAssertEqual(activity.inputTokens, 0)
        XCTAssertEqual(activity.outputTokens, 2)
    }

    func testCodexActivityReturnsNilWhenNoRecentFileMatchesDirectory() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try writeCodexTranscript(home: home, relative: "2026/06/15/no-cwd.jsonl", contents: #"{"type":"session_meta","payload":{"cwd":"/other"}}"#)
        _ = try writeCodexTranscript(home: home, relative: "2026/06/15/malformed.jsonl", contents: "not-json")

        let reader = SessionActivityReader(homeURL: home, maxBytes: 10_000)

        XCTAssertNil(reader.activity(forDirectory: "/repo", agentKind: .openAICodex))
    }

    func testCodexActivityReturnsNilWhenMatchingTranscriptHasNoActivity() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try writeCodexTranscript(home: home, relative: "2026/06/15/empty.jsonl", contents: #"{"type":"session_meta","payload":{"cwd":"/repo"}}"#)

        XCTAssertNil(SessionActivityReader(homeURL: home, maxBytes: 10_000).activity(forDirectory: "/repo", agentKind: .openAICodex))
    }

    func testTailTextReturnsNilWhenExistingPathIsDirectory() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent("dir", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        XCTAssertNil(SessionActivityReader(homeURL: home, maxBytes: 100).tailText(of: dir))
    }

    func testClaudeParserCoversMissingContentTodoDefaultsAndEmptyModel() {
        let tail = """
        {"type":"assistant","message":{"id":"missing-content","usage":{"input_tokens":1}}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"Pick default active form","status":"in_progress"},{"status":"completed"}]}}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Task","input":{"description":"short"}}]}}
        """

        let activity = SessionActivity.parse(claudeJSONLTail: tail)

        XCTAssertEqual(activity.todoDone, 1)
        XCTAssertEqual(activity.todoTotal, 2)
        XCTAssertEqual(activity.activeForm, "Pick default active form")
        XCTAssertEqual(activity.lastToolActivity, "Task: short")
        XCTAssertNil(activity.model)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionActivityReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeClaudeTranscript(home: URL, directory: String, name: String, contents: String) throws -> URL {
        let projectDir = home
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(SessionActivityReader.claudeProjectDirName(forDirectory: directory), isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let url = projectDir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @discardableResult
    private func writeCodexTranscript(home: URL, relative: String, contents: String) throws -> URL {
        let url = home.appendingPathComponent(".codex/sessions", isDirectory: true).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
