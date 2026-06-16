import XCTest
@testable import OuroWorkbenchCore

/// Clean-DI / fixture-driven coverage for the last residual branches in
/// OuroWorkbenchCore — error/edge/system arms reached with real temp-dir
/// fixtures and injected closures (no test-only production scaffolding).
final class FinalCoverageTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("finalcov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    // MARK: - TranscriptTailReader

    // An empty file: readToEnd() at offset 0 returns nil, so `?? Data()` fires.
    func testTranscriptTailReaderEmptyFileYieldsEmptyText() {
        let f = tmp.appendingPathComponent("empty.log")
        FileManager.default.createFile(atPath: f.path, contents: Data())
        let tail = TranscriptTailReader().read(path: f.path)
        XCTAssertEqual(tail?.text, "")
        XCTAssertEqual(tail?.truncated, false)
    }

    // MARK: - SessionActivityReader.tailText (internal)

    // Empty file → seekToEnd 0, readToEnd nil → `?? Data()` → empty string.
    func testSessionActivityTailTextEmptyFile() {
        let f = tmp.appendingPathComponent("e.jsonl")
        FileManager.default.createFile(atPath: f.path, contents: Data())
        XCTAssertEqual(SessionActivityReader(homeURL: tmp, maxBytes: 10).tailText(of: f), "")
    }

    // File larger than the cap → the `size > maxBytes` offset branch seeks to tail.
    func testSessionActivityTailTextSeeksToTailWhenLargerThanCap() throws {
        let f = tmp.appendingPathComponent("big.jsonl")
        try String(repeating: "x", count: 100).write(to: f, atomically: true, encoding: .utf8)
        let tail = SessionActivityReader(homeURL: tmp, maxBytes: 10).tailText(of: f)
        XCTAssertEqual(tail, String(repeating: "x", count: 10))
    }

    // MARK: - SessionActivityReader filesystem walks (private helpers via public API)

    // No ~/.codex/sessions root → recentFiles enumerator is nil → returns [].
    func testSessionActivityCodexScanWithNoSessionsRootReturnsNil() {
        let reader = SessionActivityReader(homeURL: tmp, maxBytes: 256_000)
        XCTAssertNil(reader.activity(forDirectory: "/some/dir", agentKind: .openAICodex))
    }

    // A candidate `.jsonl` that is actually a DIRECTORY → FileHandle open fails
    // in codexHeadCwd → nil, tolerated.
    func testSessionActivityCodexHeadOpenFailureIsTolerated() throws {
        let day = tmp.appendingPathComponent(".codex/sessions/2026/06/15", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: day.appendingPathComponent("x.jsonl"), withIntermediateDirectories: true)
        let reader = SessionActivityReader(homeURL: tmp, maxBytes: 256_000)
        XCTAssertNil(reader.activity(forDirectory: "/no/match", agentKind: .openAICodex))
    }

    // An empty rollout file → read(upToCount:) nil → `?? Data()`, no cwd → nil.
    func testSessionActivityCodexEmptyRolloutFileYieldsNoMatch() throws {
        let day = tmp.appendingPathComponent(".codex/sessions/2026/06/15", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: day.appendingPathComponent("x.jsonl").path, contents: Data())
        let reader = SessionActivityReader(homeURL: tmp, maxBytes: 256_000)
        XCTAssertNil(reader.activity(forDirectory: "/no/match", agentKind: .openAICodex))
    }

    // Two candidate `.jsonl` (a real one + a broken symlink) force the recency
    // comparator to read each one's mod-date; the broken link's resourceValues
    // throws → `?? .distantPast`.
    func testSessionActivityModificationDateBrokenSymlinkIsDistantPast() throws {
        let encoded = SessionActivityReader.claudeProjectDirName(forDirectory: "/work/dir")
        let projectDir = tmp.appendingPathComponent(".claude/projects/\(encoded)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: projectDir.appendingPathComponent("real.jsonl").path, contents: Data())
        try FileManager.default.createSymbolicLink(
            at: projectDir.appendingPathComponent("dangling.jsonl"),
            withDestinationURL: tmp.appendingPathComponent("nonexistent-target.jsonl"))
        let reader = SessionActivityReader(homeURL: tmp, maxBytes: 256_000)
        XCTAssertNil(reader.activity(forDirectory: "/work/dir", agentKind: .claudeCode))
    }
}
