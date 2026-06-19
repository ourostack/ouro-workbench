import XCTest
@testable import OuroWorkbenchCore

final class AgentSessionRecordTests: XCTestCase {
    // MARK: - AgentHarness

    func testHarnessRawValuesAreStable() {
        XCTAssertEqual(AgentHarness.claudeCode.rawValue, "claudeCode")
        XCTAssertEqual(AgentHarness.githubCopilotCLI.rawValue, "githubCopilotCLI")
        XCTAssertEqual(AgentHarness.openAICodex.rawValue, "openAICodex")
        XCTAssertEqual(AgentHarness.custom.rawValue, "custom")
    }

    func testHarnessDecodesKnownRawValues() throws {
        for harness in AgentHarness.allCases {
            let json = Data("\"\(harness.rawValue)\"".utf8)
            let decoded = try JSONDecoder().decode(AgentHarness.self, from: json)
            XCTAssertEqual(decoded, harness)
        }
    }

    func testHarnessDecodesUnknownRawValueToCustom() throws {
        let json = Data("\"somethingNewFromANewerBuild\"".utf8)
        let decoded = try JSONDecoder().decode(AgentHarness.self, from: json)
        XCTAssertEqual(decoded, .custom)
    }

    func testHarnessEncodesRawValue() throws {
        let data = try JSONEncoder().encode(AgentHarness.openAICodex)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"openAICodex\"")
    }

    // MARK: - AgentSessionRecord

    func testRecordRoundTripsWithAllFields() throws {
        let record = AgentSessionRecord(
            harness: .claudeCode,
            sessionId: "abc-123",
            cwd: "/Users/me/project",
            repository: "owner/repo",
            branch: "main",
            title: "Fix the thing",
            lastActive: Date(timeIntervalSince1970: 1_700_000_000),
            running: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let decoded = try decoder.decode(AgentSessionRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }

    func testRecordRoundTripsWithNilOptionalFields() throws {
        let record = AgentSessionRecord(
            harness: .githubCopilotCLI,
            sessionId: "only-id",
            cwd: "/tmp",
            repository: nil,
            branch: nil,
            title: nil,
            lastActive: nil,
            running: false
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(AgentSessionRecord.self, from: data)
        XCTAssertEqual(decoded, record)
        XCTAssertNil(decoded.repository)
        XCTAssertNil(decoded.branch)
        XCTAssertNil(decoded.title)
        XCTAssertNil(decoded.lastActive)
    }

    func testRecordIdIsHarnessAndSessionId() {
        let record = AgentSessionRecord(
            harness: .openAICodex,
            sessionId: "sid",
            cwd: "/x",
            running: false
        )
        XCTAssertEqual(record.id, "openAICodex:sid")
    }

    func testRecordDefaultsOptionalsToNil() {
        let record = AgentSessionRecord(
            harness: .custom,
            sessionId: "s",
            cwd: "/c",
            running: true
        )
        XCTAssertNil(record.repository)
        XCTAssertNil(record.branch)
        XCTAssertNil(record.title)
        XCTAssertNil(record.lastActive)
        XCTAssertTrue(record.running)
    }

    func testRecordEquatableDistinguishesFields() {
        let base = AgentSessionRecord(harness: .claudeCode, sessionId: "a", cwd: "/c", running: false)
        XCTAssertNotEqual(base, AgentSessionRecord(harness: .openAICodex, sessionId: "a", cwd: "/c", running: false))
        XCTAssertNotEqual(base, AgentSessionRecord(harness: .claudeCode, sessionId: "b", cwd: "/c", running: false))
        XCTAssertNotEqual(base, AgentSessionRecord(harness: .claudeCode, sessionId: "a", cwd: "/d", running: false))
        XCTAssertNotEqual(base, AgentSessionRecord(harness: .claudeCode, sessionId: "a", cwd: "/c", running: true))
    }
}

// MARK: - ISO8601 parsing

final class AgentSessionScannerDateTests: XCTestCase {
    func testParseISO8601WithFractionalSeconds() {
        let date = AgentSessionScanner.parseISO8601("2026-06-19T17:58:42.177Z")
        XCTAssertNotNil(date)
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1781891922.177, accuracy: 0.01)
    }

    func testParseISO8601WithoutFractionalSeconds() {
        let date = AgentSessionScanner.parseISO8601("2026-06-19T17:58:42Z")
        XCTAssertNotNil(date)
    }

    func testParseISO8601RejectsGarbage() {
        XCTAssertNil(AgentSessionScanner.parseISO8601("not a date"))
    }

    func testParseISO8601RejectsNil() {
        XCTAssertNil(AgentSessionScanner.parseISO8601(nil))
    }
}

// MARK: - Claude recent discovery

final class AgentSessionScannerClaudeTests: XCTestCase {
    func testMissingProjectsDirectoryYieldsNoRecords() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = AgentSessionScanner(homeURL: home)
        XCTAssertEqual(scanner.discoverClaudeRecent(), [])
    }

    func testReadsTopLevelKeysFromLatestLine() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeClaudeTranscript(home: home, directory: "/Users/me/proj", name: "92cb980b.jsonl", contents: """
        {"type":"system","cwd":"/Users/me/proj","gitBranch":"feature","sessionId":"in-record-id","timestamp":"2026-06-19T10:00:00.000Z"}
        {"type":"user","cwd":"/Users/me/proj","gitBranch":"feature","sessionId":"in-record-id","timestamp":"2026-06-19T11:00:00.500Z","aiTitle":"Build the scanner"}
        """)
        let records = AgentSessionScanner(homeURL: home).discoverClaudeRecent()
        XCTAssertEqual(records.count, 1)
        let r = try XCTUnwrap(records.first)
        XCTAssertEqual(r.harness, .claudeCode)
        XCTAssertEqual(r.sessionId, "in-record-id")
        XCTAssertEqual(r.cwd, "/Users/me/proj")
        XCTAssertEqual(r.branch, "feature")
        XCTAssertEqual(r.title, "Build the scanner")
        XCTAssertFalse(r.running)
        XCTAssertEqual(r.lastActive, AgentSessionScanner.parseISO8601("2026-06-19T11:00:00.500Z"))
    }

    func testFallsBackToFilenameWhenSessionIdAbsent() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeClaudeTranscript(home: home, directory: "/repo", name: "file-stem-id.jsonl", contents: """
        {"type":"user","cwd":"/repo","timestamp":"2026-06-19T11:00:00.000Z"}
        """)
        let r = try XCTUnwrap(AgentSessionScanner(homeURL: home).discoverClaudeRecent().first)
        XCTAssertEqual(r.sessionId, "file-stem-id")
        XCTAssertNil(r.branch)
        XCTAssertNil(r.title)
    }

    func testSummaryUsedWhenAiTitleAbsent() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeClaudeTranscript(home: home, directory: "/repo", name: "s.jsonl", contents: """
        {"type":"summary","cwd":"/repo","sessionId":"sid","timestamp":"2026-06-19T11:00:00.000Z","summary":"A summary title"}
        """)
        let r = try XCTUnwrap(AgentSessionScanner(homeURL: home).discoverClaudeRecent().first)
        XCTAssertEqual(r.title, "A summary title")
    }

    func testMalformedLinesAreSkippedButValidLineStillRead() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeClaudeTranscript(home: home, directory: "/repo", name: "s.jsonl", contents: """
        not json at all
        {"type":"user","cwd":"/repo","sessionId":"sid","timestamp":"2026-06-19T11:00:00.000Z"}
        {"broken
        """)
        let r = try XCTUnwrap(AgentSessionScanner(homeURL: home).discoverClaudeRecent().first)
        XCTAssertEqual(r.sessionId, "sid")
    }

    func testMissingAndBadTimestampLeavesLastActiveNil() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeClaudeTranscript(home: home, directory: "/repo", name: "s.jsonl", contents: """
        {"type":"user","cwd":"/repo","sessionId":"sid","timestamp":"garbage"}
        """)
        let r = try XCTUnwrap(AgentSessionScanner(homeURL: home).discoverClaudeRecent().first)
        XCTAssertNil(r.lastActive)
    }

    func testFileWithNoUsableLinesYieldsNoRecord() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        // No line carries a cwd → nothing to anchor a record on.
        try writeClaudeTranscript(home: home, directory: "/repo", name: "s.jsonl", contents: """
        {"type":"user"}
        """)
        XCTAssertEqual(AgentSessionScanner(homeURL: home).discoverClaudeRecent(), [])
    }

    func testMultipleProjectDirsAndFilesEachProduceARecord() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeClaudeTranscript(home: home, directory: "/a", name: "a1.jsonl", contents: """
        {"type":"user","cwd":"/a","sessionId":"a1","timestamp":"2026-06-19T11:00:00.000Z"}
        """)
        try writeClaudeTranscript(home: home, directory: "/a", name: "a2.jsonl", contents: """
        {"type":"user","cwd":"/a","sessionId":"a2","timestamp":"2026-06-19T11:00:00.000Z"}
        """)
        try writeClaudeTranscript(home: home, directory: "/b", name: "b1.jsonl", contents: """
        {"type":"user","cwd":"/b","sessionId":"b1","timestamp":"2026-06-19T11:00:00.000Z"}
        """)
        let ids = Set(AgentSessionScanner(homeURL: home).discoverClaudeRecent().map(\.sessionId))
        XCTAssertEqual(ids, ["a1", "a2", "b1"])
    }

    func testNonJSONLFilesAreIgnored() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let projectDir = home
            .appendingPathComponent(".claude/projects/-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try Data("ignore me".utf8).write(to: projectDir.appendingPathComponent("notes.txt"))
        XCTAssertEqual(AgentSessionScanner(homeURL: home).discoverClaudeRecent(), [])
    }

    func testFileEntryInProjectsRootIsSkipped() throws {
        // A non-directory entry directly under projects/ → contentsOfDirectory
        // on it throws → the `else { continue }` arm is taken.
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let projectsDir = home.appendingPathComponent(".claude/projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        try Data("not a dir".utf8).write(to: projectsDir.appendingPathComponent("stray-file"))
        // Plus one real session so the loop still produces a record.
        try writeClaudeTranscript(home: home, directory: "/repo", name: "s.jsonl", contents: """
        {"type":"user","cwd":"/repo","sessionId":"sid","timestamp":"2026-06-19T11:00:00.000Z"}
        """)
        let ids = AgentSessionScanner(homeURL: home).discoverClaudeRecent().map(\.sessionId)
        XCTAssertEqual(ids, ["sid"])
    }

    func testEmptyJsonlFileYieldsNoRecord() throws {
        // A zero-byte .jsonl → tailText returns "" → no usable line → skipped.
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeClaudeTranscript(home: home, directory: "/repo", name: "empty.jsonl", contents: "")
        XCTAssertEqual(AgentSessionScanner(homeURL: home).discoverClaudeRecent(), [])
    }

    func testLargeTranscriptIsTailedToLatestLine() throws {
        // A transcript larger than maxBytes exercises the size>maxBytes tail
        // offset; the LATEST line still wins.
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let padding = String(repeating: "{\"type\":\"noise\"}\n", count: 500)
        let contents = padding + """
        {"type":"user","cwd":"/repo","sessionId":"tail-sid","timestamp":"2026-06-19T11:00:00.000Z"}
        """
        try writeClaudeTranscript(home: home, directory: "/repo", name: "big.jsonl", contents: contents)
        let scanner = AgentSessionScanner(homeURL: home, maxBytes: 200)
        let r = try XCTUnwrap(scanner.discoverClaudeRecent().first)
        XCTAssertEqual(r.sessionId, "tail-sid")
    }

    func testZeroMaxBytesReadsNothing() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeClaudeTranscript(home: home, directory: "/repo", name: "s.jsonl", contents: """
        {"type":"user","cwd":"/repo","sessionId":"sid","timestamp":"2026-06-19T11:00:00.000Z"}
        """)
        let scanner = AgentSessionScanner(homeURL: home, maxBytes: 0)
        XCTAssertEqual(scanner.discoverClaudeRecent(), [])
    }

    func testTailTextReturnsNilForDirectoryAndMissingFile() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = AgentSessionScanner(homeURL: home, maxBytes: 100)
        // A directory path: fileExists is true but FileHandle(forReadingFrom:)
        // throws → the catch arm returns nil.
        let dir = home.appendingPathComponent("a-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertNil(scanner.tailText(of: dir))
        // A missing file: fileExists is false → early nil.
        XCTAssertNil(scanner.tailText(of: home.appendingPathComponent("nope.jsonl")))
        // maxBytes == 0 → early nil even for a real file.
        let real = home.appendingPathComponent("real.txt")
        try Data("hello".utf8).write(to: real)
        XCTAssertNil(AgentSessionScanner(homeURL: home, maxBytes: 0).tailText(of: real))
    }

    // MARK: helpers

    @discardableResult
    func writeClaudeTranscript(home: URL, directory: String, name: String, contents: String) throws -> URL {
        let projectDir = home
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(SessionActivityReader.claudeProjectDirName(forDirectory: directory), isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let url = projectDir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Command → harness matcher

final class AgentHarnessClassifyTests: XCTestCase {
    func testClassifiesBareBinaries() {
        XCTAssertEqual(AgentHarness.classify(command: "claude"), .claudeCode)
        XCTAssertEqual(AgentHarness.classify(command: "copilot"), .githubCopilotCLI)
        XCTAssertEqual(AgentHarness.classify(command: "codex"), .openAICodex)
    }

    func testClassifiesPathPrefixedBinaries() {
        XCTAssertEqual(AgentHarness.classify(command: "/usr/local/bin/claude"), .claudeCode)
        XCTAssertEqual(AgentHarness.classify(command: "/opt/homebrew/bin/copilot"), .githubCopilotCLI)
        XCTAssertEqual(AgentHarness.classify(command: "/Users/me/.local/bin/codex"), .openAICodex)
    }

    func testClassifiesBinariesWithArguments() {
        XCTAssertEqual(AgentHarness.classify(command: "claude --resume abc"), .claudeCode)
        XCTAssertEqual(AgentHarness.classify(command: "/usr/local/bin/codex exec --json"), .openAICodex)
        XCTAssertEqual(AgentHarness.classify(command: "  copilot   --continue  "), .githubCopilotCLI)
    }

    func testNonAgentCommandsReturnNil() {
        XCTAssertNil(AgentHarness.classify(command: "node server.js"))
        XCTAssertNil(AgentHarness.classify(command: "/usr/bin/vim"))
        XCTAssertNil(AgentHarness.classify(command: "git status"))
    }

    func testEmptyOrWhitespaceCommandReturnsNil() {
        XCTAssertNil(AgentHarness.classify(command: ""))
        XCTAssertNil(AgentHarness.classify(command: "   "))
    }

    func testMatchIsCaseSensitiveOnBinaryName() {
        // The harness binaries are lowercase on disk; an upper/mixed-case token
        // is a different program and must not classify.
        XCTAssertNil(AgentHarness.classify(command: "Claude"))
        XCTAssertNil(AgentHarness.classify(command: "CODEX"))
    }

    func testSubstringInLargerWordDoesNotMatch() {
        // A binary whose name merely CONTAINS an agent name must not classify —
        // only the exact basename of the leading token counts.
        XCTAssertNil(AgentHarness.classify(command: "claude-helper"))
        XCTAssertNil(AgentHarness.classify(command: "my-codex-wrapper"))
        XCTAssertNil(AgentHarness.classify(command: "/usr/bin/copilotish"))
    }

    func testSlashOnlyTokenFallsBackToWholeTokenAndDoesNotMatch() {
        // A leading token of only slashes splits to nothing, so the basename
        // falls back to the whole token — which is not an agent binary.
        XCTAssertNil(AgentHarness.classify(command: "/ arg"))
        XCTAssertNil(AgentHarness.classify(command: "///"))
    }
}

// MARK: - Running discovery

final class AgentSessionScannerRunningTests: XCTestCase {
    func testClassifiesEachHarnessFromProcessLines() {
        let lister: @Sendable () -> [RunningProcessLine] = {
            [
                RunningProcessLine(pid: 100, command: "claude --resume", cwd: "/a"),
                RunningProcessLine(pid: 200, command: "/usr/local/bin/copilot", cwd: "/b"),
                RunningProcessLine(pid: 300, command: "codex exec", cwd: "/c")
            ]
        }
        let records = AgentSessionScanner().discoverRunning(processLister: lister)
            .sorted { $0.cwd < $1.cwd }
        XCTAssertEqual(records.map(\.harness), [.claudeCode, .githubCopilotCLI, .openAICodex])
        XCTAssertTrue(records.allSatisfy(\.running))
        XCTAssertEqual(records.map(\.cwd), ["/a", "/b", "/c"])
    }

    func testNonAgentLinesAreSkipped() {
        let lister: @Sendable () -> [RunningProcessLine] = {
            [
                RunningProcessLine(pid: 1, command: "node server.js", cwd: "/a"),
                RunningProcessLine(pid: 2, command: "claude", cwd: "/b")
            ]
        }
        let records = AgentSessionScanner().discoverRunning(processLister: lister)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.harness, .claudeCode)
    }

    func testEmptyProcessListYieldsNoRecords() {
        let records = AgentSessionScanner().discoverRunning(processLister: { [] })
        XCTAssertEqual(records, [])
    }

    func testSessionIdDerivesFromPidWhenNoBetterSource() {
        let lister: @Sendable () -> [RunningProcessLine] = {
            [RunningProcessLine(pid: 4242, command: "claude", cwd: "/a")]
        }
        let r = AgentSessionScanner().discoverRunning(processLister: lister).first
        XCTAssertEqual(r?.sessionId, "pid-4242")
    }

    func testMissingCwdBecomesEmptyString() {
        let lister: @Sendable () -> [RunningProcessLine] = {
            [RunningProcessLine(pid: 5, command: "codex", cwd: nil)]
        }
        let r = AgentSessionScanner().discoverRunning(processLister: lister).first
        XCTAssertEqual(r?.cwd, "")
        XCTAssertFalse(r?.running == false)
    }
}

// MARK: - ps output parsing (pure, fed by the App/MCP-side Process shell)

final class RunningProcessLineParsePSTests: XCTestCase {
    func testParsesPidAndFullCommandPerLine() {
        let output = """
          1234 /usr/local/bin/claude --resume abc
          5678 node /path/server.js
        """
        let lines = RunningProcessLine.parsePS(output)
        XCTAssertEqual(lines, [
            RunningProcessLine(pid: 1234, command: "/usr/local/bin/claude --resume abc", cwd: nil),
            RunningProcessLine(pid: 5678, command: "node /path/server.js", cwd: nil)
        ])
    }

    func testLeadingWhitespaceBeforePidIsTolerated() {
        // `ps -o pid=` right-aligns pids in a width-padded column, so most
        // lines arrive with leading spaces — they must not break the split.
        let output = "    42 claude\n999999 codex exec"
        let lines = RunningProcessLine.parsePS(output)
        XCTAssertEqual(lines, [
            RunningProcessLine(pid: 42, command: "claude", cwd: nil),
            RunningProcessLine(pid: 999999, command: "codex exec", cwd: nil)
        ])
    }

    func testBlankAndWhitespaceOnlyLinesAreSkipped() {
        let output = "\n  \n  100 claude\n\t\n"
        let lines = RunningProcessLine.parsePS(output)
        XCTAssertEqual(lines, [RunningProcessLine(pid: 100, command: "claude", cwd: nil)])
    }

    func testNonIntegerPidLinesAreSkipped() {
        // A header row (`PID COMMAND`) or any malformed first token (no integer
        // pid) is dropped rather than mis-parsed.
        let output = "PID COMMAND\nabc claude\n200 copilot"
        let lines = RunningProcessLine.parsePS(output)
        XCTAssertEqual(lines, [RunningProcessLine(pid: 200, command: "copilot", cwd: nil)])
    }

    func testLineWithPidButNoCommandIsSkipped() {
        // A bare pid with no command has nothing to classify — skip it.
        let output = "100\n  200  \n300 claude"
        let lines = RunningProcessLine.parsePS(output)
        XCTAssertEqual(lines, [RunningProcessLine(pid: 300, command: "claude", cwd: nil)])
    }

    func testCommandWithInternalMultipleSpacesIsPreserved() {
        // Only the FIRST whitespace run (pid/command boundary) is consumed;
        // the command keeps its own spacing verbatim.
        let output = "5 claude   --flag   value"
        let lines = RunningProcessLine.parsePS(output)
        XCTAssertEqual(lines, [RunningProcessLine(pid: 5, command: "claude   --flag   value", cwd: nil)])
    }

    func testEmptyOutputYieldsNoLines() {
        XCTAssertEqual(RunningProcessLine.parsePS(""), [])
    }

    func testCarriageReturnsAreStrippedFromCommand() {
        // Defensive: a stray CR (CRLF-ish output) must not leak into the command.
        let output = "7 claude --resume\r\n8 codex\r"
        let lines = RunningProcessLine.parsePS(output)
        XCTAssertEqual(lines, [
            RunningProcessLine(pid: 7, command: "claude --resume", cwd: nil),
            RunningProcessLine(pid: 8, command: "codex", cwd: nil)
        ])
    }
}

// MARK: - Unified scan + dedup

final class AgentSessionScannerScanTests: XCTestCase {
    func testEmptyEverythingYieldsEmpty() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let records = AgentSessionScanner(homeURL: home).scan(processLister: { [] })
        XCTAssertEqual(records, [])
    }

    func testMergesRecentAndRunning() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeClaudeTranscript(home: home, directory: "/proj", name: "s.jsonl", contents: """
        {"type":"user","cwd":"/proj","sessionId":"recent-sid","timestamp":"2026-06-19T10:00:00.000Z"}
        """)
        let lister: @Sendable () -> [RunningProcessLine] = {
            [RunningProcessLine(pid: 9, command: "codex", cwd: "/other")]
        }
        let records = AgentSessionScanner(homeURL: home).scan(processLister: lister)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.contains { $0.sessionId == "recent-sid" })
        XCTAssertTrue(records.contains { $0.harness == .openAICodex && $0.running })
    }

    func testRunningOverridesRecentOnSameSessionId() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        // A recent Claude session whose sessionId equals the running record's id.
        try writeClaudeTranscript(home: home, directory: "/proj", name: "pid-77.jsonl", contents: """
        {"type":"user","cwd":"/proj","sessionId":"pid-77","timestamp":"2026-06-19T10:00:00.000Z"}
        """)
        let lister: @Sendable () -> [RunningProcessLine] = {
            [RunningProcessLine(pid: 77, command: "claude", cwd: "/proj")]
        }
        let records = AgentSessionScanner(homeURL: home).scan(processLister: lister)
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records.first?.running == true)
    }

    func testDedupCollapsesSameHarnessAndCwd() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        // Two recent Claude sessions in the SAME cwd but different sessionIds.
        // Same harness+cwd → collapse to one (the more-recent one wins).
        try writeClaudeTranscript(home: home, directory: "/proj", name: "old.jsonl", contents: """
        {"type":"user","cwd":"/proj","sessionId":"old","timestamp":"2026-06-19T09:00:00.000Z"}
        """)
        try writeClaudeTranscript(home: home, directory: "/proj", name: "new.jsonl", contents: """
        {"type":"user","cwd":"/proj","sessionId":"new","timestamp":"2026-06-19T12:00:00.000Z"}
        """)
        let records = AgentSessionScanner(homeURL: home).scan(processLister: { [] })
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.sessionId, "new")
    }

    // Direct, FS-order-independent tests of the pure dedup/sort core so the
    // collision branch arms are deterministically exercised.
    func testMergeKeepsExistingWhenCandidateNotNewer() {
        let older = AgentSessionRecord(harness: .claudeCode, sessionId: "old", cwd: "/proj",
                                       lastActive: Date(timeIntervalSince1970: 100), running: false)
        let newer = AgentSessionRecord(harness: .claudeCode, sessionId: "new", cwd: "/proj",
                                       lastActive: Date(timeIntervalSince1970: 200), running: false)
        // existing = newer (first), candidate = older (second, NOT newer) → keep newer.
        let merged = AgentSessionScanner.merge(running: [], recent: [newer, older])
        XCTAssertEqual(merged.map(\.sessionId), ["new"])
    }

    func testMergeReplacesExistingWhenCandidateIsNewer() {
        let older = AgentSessionRecord(harness: .claudeCode, sessionId: "old", cwd: "/proj",
                                       lastActive: Date(timeIntervalSince1970: 100), running: false)
        let newer = AgentSessionRecord(harness: .claudeCode, sessionId: "new", cwd: "/proj",
                                       lastActive: Date(timeIntervalSince1970: 200), running: false)
        // existing = older (first), candidate = newer (second) → replace with newer.
        let merged = AgentSessionScanner.merge(running: [], recent: [older, newer])
        XCTAssertEqual(merged.map(\.sessionId), ["new"])
    }

    func testMergeCollisionWithNilTimestampsKeepsFirst() {
        let a = AgentSessionRecord(harness: .claudeCode, sessionId: "first", cwd: "/proj",
                                   lastActive: nil, running: false)
        let b = AgentSessionRecord(harness: .claudeCode, sessionId: "second", cwd: "/proj",
                                   lastActive: nil, running: false)
        // Both nil → neither strictly newer → first stays.
        let merged = AgentSessionScanner.merge(running: [], recent: [a, b])
        XCTAssertEqual(merged.map(\.sessionId), ["first"])
    }

    func testSortsByLastActiveDescThenRunningFirst() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeClaudeTranscript(home: home, directory: "/older", name: "a.jsonl", contents: """
        {"type":"user","cwd":"/older","sessionId":"older","timestamp":"2026-06-19T08:00:00.000Z"}
        """)
        try writeClaudeTranscript(home: home, directory: "/newer", name: "b.jsonl", contents: """
        {"type":"user","cwd":"/newer","sessionId":"newer","timestamp":"2026-06-19T20:00:00.000Z"}
        """)
        // A running record with NO lastActive must sort ahead of dated recents.
        let lister: @Sendable () -> [RunningProcessLine] = {
            [RunningProcessLine(pid: 1, command: "codex", cwd: "/live")]
        }
        let records = AgentSessionScanner(homeURL: home).scan(processLister: lister)
        XCTAssertEqual(records.map(\.sessionId), ["pid-1", "newer", "older"])
    }

    func testSortIsStableForEqualKeys() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        // Two running records, same (nil lastActive, running) ordering key:
        // ordering falls back to id for determinism.
        let lister: @Sendable () -> [RunningProcessLine] = {
            [
                RunningProcessLine(pid: 2, command: "codex", cwd: "/b"),
                RunningProcessLine(pid: 1, command: "claude", cwd: "/a")
            ]
        }
        let first = AgentSessionScanner(homeURL: home).scan(processLister: lister)
        let second = AgentSessionScanner(homeURL: home).scan(processLister: lister)
        XCTAssertEqual(first, second)
    }

    // MARK: helpers

    @discardableResult
    func writeClaudeTranscript(home: URL, directory: String, name: String, contents: String) throws -> URL {
        let projectDir = home
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(SessionActivityReader.claudeProjectDirName(forDirectory: directory), isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let url = projectDir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Copilot recent discovery

final class AgentSessionScannerCopilotTests: XCTestCase {
    func testMissingSessionStateDirectoryYieldsNoRecords() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(AgentSessionScanner(homeURL: home).discoverCopilotRecent(), [])
    }

    func testReadsFlatYamlFields() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeCopilotWorkspace(home: home, dir: "90634a63", contents: """
        id: in-file-id
        cwd: /Users/me/ms-desk
        git_root: /Users/me/ms-desk
        repository: arimendelow_microsoft/desk
        host_type: github
        branch: main
        name: Plan Move to GHCP CLI
        created_at: 2026-06-19T17:49:44.603Z
        updated_at: 2026-06-19T17:58:42.177Z
        """)
        let r = try XCTUnwrap(AgentSessionScanner(homeURL: home).discoverCopilotRecent().first)
        XCTAssertEqual(r.harness, .githubCopilotCLI)
        XCTAssertEqual(r.sessionId, "in-file-id")
        XCTAssertEqual(r.cwd, "/Users/me/ms-desk")
        XCTAssertEqual(r.repository, "arimendelow_microsoft/desk")
        XCTAssertEqual(r.branch, "main")
        XCTAssertEqual(r.title, "Plan Move to GHCP CLI")
        XCTAssertFalse(r.running)
        XCTAssertEqual(r.lastActive, AgentSessionScanner.parseISO8601("2026-06-19T17:58:42.177Z"))
    }

    func testFallsBackToDirNameWhenIdAbsent() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeCopilotWorkspace(home: home, dir: "dir-as-id", contents: """
        cwd: /repo
        """)
        let r = try XCTUnwrap(AgentSessionScanner(homeURL: home).discoverCopilotRecent().first)
        XCTAssertEqual(r.sessionId, "dir-as-id")
        XCTAssertNil(r.repository)
        XCTAssertNil(r.branch)
        XCTAssertNil(r.title)
    }

    func testFallsBackToCreatedAtWhenUpdatedAtAbsent() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeCopilotWorkspace(home: home, dir: "d", contents: """
        id: d
        cwd: /repo
        created_at: 2026-06-19T10:00:00.000Z
        """)
        let r = try XCTUnwrap(AgentSessionScanner(homeURL: home).discoverCopilotRecent().first)
        XCTAssertEqual(r.lastActive, AgentSessionScanner.parseISO8601("2026-06-19T10:00:00.000Z"))
    }

    func testBadTimestampLeavesLastActiveNil() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeCopilotWorkspace(home: home, dir: "d", contents: """
        id: d
        cwd: /repo
        updated_at: nonsense
        """)
        let r = try XCTUnwrap(AgentSessionScanner(homeURL: home).discoverCopilotRecent().first)
        XCTAssertNil(r.lastActive)
    }

    func testEmptyYamlOrNoCwdYieldsNoRecord() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeCopilotWorkspace(home: home, dir: "empty", contents: "")
        try writeCopilotWorkspace(home: home, dir: "nocwd", contents: "id: x\nname: titled")
        XCTAssertEqual(AgentSessionScanner(homeURL: home).discoverCopilotRecent(), [])
    }

    func testSessionDirWithoutWorkspaceYamlIsSkipped() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionDir = home.appendingPathComponent(".copilot/session-state/no-yaml", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        XCTAssertEqual(AgentSessionScanner(homeURL: home).discoverCopilotRecent(), [])
    }

    func testMultipleSessionsEachProduceARecord() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeCopilotWorkspace(home: home, dir: "one", contents: "id: one\ncwd: /a")
        try writeCopilotWorkspace(home: home, dir: "two", contents: "id: two\ncwd: /b")
        let ids = Set(AgentSessionScanner(homeURL: home).discoverCopilotRecent().map(\.sessionId))
        XCTAssertEqual(ids, ["one", "two"])
    }

    // MARK: helpers

    @discardableResult
    func writeCopilotWorkspace(home: URL, dir: String, contents: String) throws -> URL {
        let sessionDir = home
            .appendingPathComponent(".copilot/session-state", isDirectory: true)
            .appendingPathComponent(dir, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let url = sessionDir.appendingPathComponent("workspace.yaml")
        try Data(contents.utf8).write(to: url)
        return url
    }

    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
