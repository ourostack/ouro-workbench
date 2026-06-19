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
