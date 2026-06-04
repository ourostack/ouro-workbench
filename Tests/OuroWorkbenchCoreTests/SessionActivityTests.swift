import XCTest
@testable import OuroWorkbenchCore

final class SessionActivityTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    // MARK: - Claude parse: todo progress

    func testTodoProgressFromLatestSnapshot() {
        // Two TodoWrite snapshots; the LATEST one wins (full snapshot semantics).
        let tail = [
            assistantLine(todos: [
                ["content": "A", "status": "completed", "activeForm": "Doing A"],
                ["content": "B", "status": "pending", "activeForm": "Doing B"],
                ["content": "C", "status": "pending", "activeForm": "Doing C"]
            ]),
            assistantLine(todos: [
                ["content": "A", "status": "completed", "activeForm": "Doing A"],
                ["content": "B", "status": "completed", "activeForm": "Doing B"],
                ["content": "C", "status": "in_progress", "activeForm": "Doing C"]
            ])
        ].joined(separator: "\n")

        let activity = SessionActivity.parse(claudeJSONLTail: tail)
        XCTAssertEqual(activity.todoDone, 2)
        XCTAssertEqual(activity.todoTotal, 3)
        XCTAssertEqual(activity.activeForm, "Doing C")
        XCTAssertEqual(activity.todoLabel, "2/3")
    }

    func testActiveFormFallsBackToContentWhenMissing() {
        let tail = assistantLine(todos: [
            ["content": "Work item", "status": "in_progress"]
        ])
        let activity = SessionActivity.parse(claudeJSONLTail: tail)
        XCTAssertEqual(activity.activeForm, "Work item")
    }

    // MARK: - Claude parse: tokens (sum + de-dup by message id)

    func testTokensSummedAcrossMessages() {
        let tail = [
            usageLine(id: "m1", input: 10, output: 20, cacheRead: 100, cacheCreate: 5),
            usageLine(id: "m2", input: 3, output: 7, cacheRead: 50, cacheCreate: 0)
        ].joined(separator: "\n")
        let a = SessionActivity.parse(claudeJSONLTail: tail)
        XCTAssertEqual(a.inputTokens, 13)
        XCTAssertEqual(a.outputTokens, 27)
        XCTAssertEqual(a.cacheReadTokens, 150)
        XCTAssertEqual(a.cacheCreationTokens, 5)
    }

    func testUsageDeduplicatedByMessageID() {
        // The same logical assistant message is split across 3 lines that each
        // repeat the SAME usage — must be counted once, not three times.
        let line = usageLine(id: "dup", input: 6, output: 874, cacheRead: 0, cacheCreate: 0)
        let tail = [line, line, line].joined(separator: "\n")
        let a = SessionActivity.parse(claudeJSONLTail: tail)
        XCTAssertEqual(a.outputTokens, 874, "duplicate message ids must not multiply usage")
        XCTAssertEqual(a.inputTokens, 6)
    }

    func testModelPickedByMajorityAndSyntheticIgnored() {
        let tail = [
            usageLine(id: "a", input: 1, output: 1, model: "claude-opus-4-8"),
            usageLine(id: "b", input: 1, output: 1, model: "claude-opus-4-8"),
            usageLine(id: "c", input: 1, output: 1, model: "<synthetic>")
        ].joined(separator: "\n")
        let a = SessionActivity.parse(claudeJSONLTail: tail)
        XCTAssertEqual(a.model, "claude-opus-4-8")
    }

    // MARK: - Claude parse: tool activity + redaction

    func testLastToolActivityShowsBasenameNotFullPath() {
        let tail = toolUseLine(name: "Edit", input: ["file_path": "/Users/secret/Projects/app/src/foo.ts"])
        let a = SessionActivity.parse(claudeJSONLTail: tail)
        XCTAssertEqual(a.lastToolActivity, "Edit foo.ts")
    }

    func testBashToolRedactsToLeadingCommandWordOnly() {
        // The command embeds a secret in its args — only the leading word leaks.
        let tail = toolUseLine(name: "Bash", input: ["command": "curl -H 'Authorization: Bearer sk-SECRET' https://x"])
        let a = SessionActivity.parse(claudeJSONLTail: tail)
        XCTAssertEqual(a.lastToolActivity, "Bash curl")
        XCTAssertFalse(a.lastToolActivity?.contains("SECRET") ?? true)
    }

    func testMCPToolNameShortenedToTrailingSegment() {
        let tail = toolUseLine(name: "mcp__computer-use__screenshot", input: [:])
        let a = SessionActivity.parse(claudeJSONLTail: tail)
        XCTAssertEqual(a.lastToolActivity, "screenshot")
    }

    func testToolResultContentIsNeverSurfaced() {
        // A user/tool_result line embeds file contents with a secret. The parser
        // ignores non-assistant lines entirely, so nothing leaks.
        let toolResult = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"FILE CONTENTS WITH sk-SECRET TOKEN"}]}}"#
        let a = SessionActivity.parse(claudeJSONLTail: toolResult)
        XCTAssertTrue(a.isEmpty)
        XCTAssertNil(a.lastToolActivity)
    }

    // MARK: - Robustness

    func testMalformedLinesSkipped() {
        let tail = [
            "this is not json at all {",
            usageLine(id: "ok", input: 5, output: 5),
            #"{"type":"assistant"}"#, // missing message — skipped, not fatal
            "{ partial json"
        ].joined(separator: "\n")
        let a = SessionActivity.parse(claudeJSONLTail: tail)
        XCTAssertEqual(a.inputTokens, 5)
        XCTAssertEqual(a.outputTokens, 5)
    }

    func testEmptyTailIsEmpty() {
        XCTAssertTrue(SessionActivity.parse(claudeJSONLTail: "").isEmpty)
    }

    func testPartialFirstLineFromByteTailIsSkipped() {
        // A byte-bounded tail usually starts mid-line; that fragment must be
        // skipped without breaking the rest.
        let tail = "_input_tokens\":13133}}}\n" + usageLine(id: "m", input: 1, output: 2)
        let a = SessionActivity.parse(claudeJSONLTail: tail)
        XCTAssertEqual(a.outputTokens, 2)
    }

    // MARK: - Pricing

    func testPricingOpusUsesCheapCacheReads() {
        // 1M cache-read at opus should cost the cacheRead rate (1.5), not the
        // input rate (15).
        let a = SessionActivity(cacheReadTokens: 1_000_000, model: "claude-opus-4-8")
        XCTAssertEqual(a.usd ?? -1, 1.5, accuracy: 0.0001)
    }

    func testPricingPrefixMatchAcrossPointReleases() {
        let opus7 = SessionActivity(outputTokens: 1_000_000, model: "claude-opus-4-7").usd
        let opus8 = SessionActivity(outputTokens: 1_000_000, model: "claude-opus-4-8").usd
        XCTAssertEqual(opus7 ?? -1, 75, accuracy: 0.0001)
        XCTAssertEqual(opus8 ?? -1, 75, accuracy: 0.0001)
    }

    func testUnknownModelHasNoPrice() {
        let a = SessionActivity(outputTokens: 1_000_000, model: "some-future-model")
        XCTAssertNil(a.usd)
        XCTAssertNil(a.usdLabel)
    }

    func testUsdLabelFormatting() {
        XCTAssertEqual(SessionActivity(outputTokens: 10_000, model: "claude-sonnet-4-5").usdLabel, "$0.15")
        XCTAssertEqual(SessionActivity(outputTokens: 1_000_000, model: "claude-opus-4-8").usdLabel, "$75")
    }

    // MARK: - Session → JSONL mapping (forward-encoding)

    func testProjectDirNameEncodesSlashesAndDots() {
        // Worktree path with hyphenated segments + a dotted ".claude" — the
        // encoding is forward-only (/ and . → -), never a reverse decode.
        let dir = "/Users/a/Projects/ouro-work-substrate/.claude/worktrees/quirky-goldberg-45150a"
        XCTAssertEqual(
            SessionActivityReader.claudeProjectDirName(forDirectory: dir),
            "-Users-a-Projects-ouro-work-substrate--claude-worktrees-quirky-goldberg-45150a"
        )
    }

    func testReaderReadsTodoAndTokensFromMappedFile() throws {
        let cwd = "/Users/a/Projects/demo-app"
        let encoded = SessionActivityReader.claudeProjectDirName(forDirectory: cwd)
        let projectDir = temporaryDirectory
            .appendingPathComponent(".claude/projects/\(encoded)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let jsonl = [
            assistantLine(todos: [
                ["content": "A", "status": "completed", "activeForm": "Doing A"],
                ["content": "B", "status": "in_progress", "activeForm": "Building B"]
            ]),
            usageLine(id: "x", input: 100, output: 200, model: "claude-opus-4-8")
        ].joined(separator: "\n")
        try jsonl.write(to: projectDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let reader = SessionActivityReader(homeURL: temporaryDirectory)
        let activity = try XCTUnwrap(reader.activity(forDirectory: cwd, agentKind: .claudeCode))
        XCTAssertEqual(activity.todoDone, 1)
        XCTAssertEqual(activity.todoTotal, 2)
        XCTAssertEqual(activity.activeForm, "Building B")
        XCTAssertEqual(activity.outputTokens, 200)
        XCTAssertEqual(activity.model, "claude-opus-4-8")
    }

    func testReaderPicksMostRecentJSONLInProjectDir() throws {
        let cwd = "/Users/a/Projects/multi"
        let encoded = SessionActivityReader.claudeProjectDirName(forDirectory: cwd)
        let projectDir = temporaryDirectory
            .appendingPathComponent(".claude/projects/\(encoded)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let older = projectDir.appendingPathComponent("older.jsonl")
        try usageLine(id: "old", input: 1, output: 11).write(to: older, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: older.path)

        let newer = projectDir.appendingPathComponent("newer.jsonl")
        try usageLine(id: "new", input: 1, output: 99).write(to: newer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: newer.path)

        let reader = SessionActivityReader(homeURL: temporaryDirectory)
        let activity = try XCTUnwrap(reader.activity(forDirectory: cwd, agentKind: .claudeCode))
        XCTAssertEqual(activity.outputTokens, 99, "should read the most recently modified jsonl")
    }

    func testReaderReturnsNilWhenNoFileMapsToSession() {
        // A plain human shell whose cwd has no Claude project dir → nil, so the
        // chip degrades to its free facets.
        let reader = SessionActivityReader(homeURL: temporaryDirectory)
        XCTAssertNil(reader.activity(forDirectory: "/Users/a/no/such/project", agentKind: .claudeCode))
        XCTAssertNil(reader.activity(forDirectory: "", agentKind: .claudeCode))
    }

    // MARK: - Codex parse

    func testCodexTokensTakeLastCumulativeTotal() {
        // token_count.info.total_token_usage is cumulative — take the LAST.
        let tail = [
            codexTokenLine(input: 100, cached: 80, output: 5),
            codexTokenLine(input: 300, cached: 250, output: 12)
        ].joined(separator: "\n")
        let a = SessionActivity.parse(codexJSONLTail: tail)
        // non-cached input = 300 - 250 = 50
        XCTAssertEqual(a.inputTokens, 50)
        XCTAssertEqual(a.cacheReadTokens, 250)
        XCTAssertEqual(a.outputTokens, 12)
        XCTAssertEqual(a.todoTotal, 0, "Codex has no todo stream")
    }

    func testCodexLastToolActivity() {
        let tail = [
            #"{"type":"event_msg","payload":{"type":"exec_command_end"}}"#,
            #"{"type":"event_msg","payload":{"type":"patch_apply_end"}}"#
        ].joined(separator: "\n")
        let a = SessionActivity.parse(codexJSONLTail: tail)
        XCTAssertEqual(a.lastToolActivity, "Apply patch")
    }

    // MARK: - Fixtures

    private func assistantLine(todos: [[String: Any]]) -> String {
        jsonLine([
            "type": "assistant",
            "message": [
                "role": "assistant",
                "model": "claude-opus-4-8",
                "id": "todo-\(UUID().uuidString)",
                "content": [
                    ["type": "tool_use", "name": "TodoWrite", "input": ["todos": todos]]
                ]
            ]
        ])
    }

    private func usageLine(
        id: String,
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheCreate: Int = 0,
        model: String = "claude-opus-4-8"
    ) -> String {
        jsonLine([
            "type": "assistant",
            "message": [
                "role": "assistant",
                "model": model,
                "id": id,
                "content": [["type": "text", "text": "hi"]],
                "usage": [
                    "input_tokens": input,
                    "output_tokens": output,
                    "cache_read_input_tokens": cacheRead,
                    "cache_creation_input_tokens": cacheCreate
                ]
            ]
        ])
    }

    private func toolUseLine(name: String, input: [String: Any]) -> String {
        jsonLine([
            "type": "assistant",
            "message": [
                "role": "assistant",
                "model": "claude-opus-4-8",
                "id": "tool-\(UUID().uuidString)",
                "content": [["type": "tool_use", "name": name, "input": input]]
            ]
        ])
    }

    private func codexTokenLine(input: Int, cached: Int, output: Int) -> String {
        jsonLine([
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": cached,
                        "output_tokens": output
                    ]
                ]
            ]
        ])
    }

    private func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}
