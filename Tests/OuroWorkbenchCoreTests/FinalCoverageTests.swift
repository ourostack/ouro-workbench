import XCTest
import Darwin
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

    // No codex rollout matches the requested cwd → the scan loop falls through
    // to `return nil`.
    func testSessionActivityCodexTranscriptURLReturnsNilWhenNothingMatches() {
        let reader = SessionActivityReader(homeURL: tmp, maxBytes: 256_000)
        XCTAssertNil(reader.codexTranscriptURL(forDirectory: "/unmatched"))
    }

    // MARK: - MailboxClient

    // Constructing with the default dataLoader evaluates the default-argument
    // expression; the URL builder resolves a normal endpoint.
    func testMailboxClientDefaultLoaderBuildsEndpointURL() throws {
        let client = MailboxClient(configuration: MailboxClientConfiguration())
        let url = try client.url(for: .machine)
        XCTAssertEqual(url.path, "/api/machine")
    }

    // MARK: - BossAgentMCPClient.ProcessIOBox.forceKill

    private final class SignalRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (pid: pid_t, sig: Int32)?
        func record(_ pid: pid_t, _ sig: Int32) { lock.lock(); stored = (pid, sig); lock.unlock() }
        func reset() { lock.lock(); stored = nil; lock.unlock() }
        var value: (pid: pid_t, sig: Int32)? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    // forceKill on a NON-own-group box signals the child pid with SIGKILL via the child-only
    // killer (injected spy), and is a no-op once the process has exited (default liveness seam).
    func testProcessIOBoxForceKillSendsSIGKILLToRunningProcessOnly() throws {
        let out = Pipe(), err = Pipe()
        let devNull = open("/dev/null", O_RDWR)
        defer { close(devNull) }
        // Real running child so the DEFAULT `isAlive` (kill(pid,0)) seam reads alive then reaped.
        let spawned = try SpawnInOwnGroup.spawn(
            executablePath: "/bin/sleep",
            arguments: ["sleep", "30"],
            environment: [:],
            stdio: SpawnInOwnGroup.StdioFDs(stdin: devNull, stdout: devNull, stderr: devNull))

        let recorder = SignalRecorder()
        // childInOwnGroup: false → forceKill must route through the CHILD-only killer (the spy),
        // never killpg. Default isAlive seam (kill(pid,0)) is exercised against the real child.
        let box = ProcessIOBox(
            pid: spawned.pid,
            stdout: out.fileHandleForReading,
            stderr: err.fileHandleForReading,
            childInOwnGroup: false,
            processKiller: { pid, sig in recorder.record(pid, sig); return 0 })

        box.forceKill()
        XCTAssertEqual(recorder.value?.sig, SIGKILL)
        XCTAssertEqual(recorder.value?.pid, spawned.pid)

        // Real cleanup (the spy did not actually kill it), then forceKill is a no-op once the
        // default liveness seam reads the child as reaped.
        kill(spawned.pid, SIGKILL)
        var status: Int32 = 0
        waitpid(spawned.pid, &status, 0)
        recorder.reset()
        box.forceKill()
        XCTAssertNil(recorder.value, "default isAlive seam must read the reaped child as gone")
    }

    // A codex rollout whose head records a matching cwd (payload form and
    // top-level form) is located by scanning, covering the match + cwd-extract arms.
    func testSessionActivityCodexMatchesByRecordedCwd() throws {
        let day = tmp.appendingPathComponent(".codex/sessions/2026/06/15", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try "{\"payload\":{\"cwd\":\"/work/dir\"}}\n"
            .write(to: day.appendingPathComponent("payload.jsonl"), atomically: true, encoding: .utf8)
        let reader = SessionActivityReader(homeURL: tmp, maxBytes: 256_000)
        // Resolves the rollout via the recorded cwd (no crash; activity may be empty).
        _ = reader.activity(forDirectory: "/work/dir", agentKind: .openAICodex)
        XCTAssertEqual(reader.codexTranscriptURL(forDirectory: "/work/dir")?.lastPathComponent, "payload.jsonl")
    }

    func testSessionActivityCodexMatchesByTopLevelCwd() throws {
        let day = tmp.appendingPathComponent(".codex/sessions/2026/06/15", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try "{\"cwd\":\"/top/level\"}\n"
            .write(to: day.appendingPathComponent("top.jsonl"), atomically: true, encoding: .utf8)
        let reader = SessionActivityReader(homeURL: tmp, maxBytes: 256_000)
        XCTAssertEqual(reader.codexTranscriptURL(forDirectory: "/top/level")?.lastPathComponent, "top.jsonl")
    }

    // MARK: - MailboxClient.defaultDataLoader (real URLSession adapter, stubbed transport)

    func testDefaultDataLoaderReturnsHTTPResponse() async throws {
        MailboxStubURLProtocol.respond = { url in
            (Data("{}".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        defer { MailboxStubURLProtocol.respond = nil }
        let (data, response) = try await MailboxClient.defaultDataLoader(
            url: URL(string: "https://example.test/api")!, session: Self.stubSession())
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, Data("{}".utf8))
    }

    func testDefaultDataLoaderRejectsNonHTTPResponse() async {
        MailboxStubURLProtocol.respond = { url in
            (Data(), URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        }
        defer { MailboxStubURLProtocol.respond = nil }
        do {
            _ = try await MailboxClient.defaultDataLoader(
                url: URL(string: "https://example.test/api")!, session: Self.stubSession())
            XCTFail("expected invalidURL")
        } catch {
            XCTAssertEqual(error as? MailboxClientError, .invalidURL)
        }
    }

    // The default-loader argument is exercised by constructing without it.
    func testMailboxClientUsesDefaultLoaderWhenUnspecified() throws {
        XCTAssertEqual(try MailboxClient().url(for: .events).path, "/api/events")
    }

    // firstTaskResult throws when the group completes without yielding (the
    // otherwise-unreachable arm behind MailboxClient/BossAgentMCPClient).
    func testFirstTaskResultThrowsOnEmptyGroup() async {
        struct Sentinel: Error {}
        do {
            _ = try await withThrowingTaskGroup(of: Int.self) { group in
                try await firstTaskResult(of: &group, orThrow: Sentinel())
            }
            XCTFail("expected the sentinel error")
        } catch {
            XCTAssertTrue(error is Sentinel)
        }
    }

    // A path the URL builder rejects surfaces as invalidURL.
    func testMailboxResolveURLRejectsUnparseablePath() {
        XCTAssertThrowsError(
            try MailboxClient.resolveURL(path: "x", relativeTo: URL(string: "http://h")!, build: { _, _ in nil })
        ) { XCTAssertEqual($0 as? MailboxClientError, .invalidURL) }
    }

    // The default loader path end-to-end: MailboxClient() with no injected loader
    // goes through defaultDataLoader → URLSession.shared, intercepted by a globally
    // registered stub.
    func testMailboxClientDefaultLoaderFetchesViaSharedSession() async throws {
        MailboxStubURLProtocol.respond = { url in
            (Data("{\"value\":7}".utf8),
             HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        URLProtocol.registerClass(MailboxStubURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(MailboxStubURLProtocol.self)
            MailboxStubURLProtocol.respond = nil
        }
        struct Payload: Decodable, Sendable { let value: Int }
        let payload: Payload = try await MailboxClient().fetch(.events)
        XCTAssertEqual(payload.value, 7)
    }

    // The percent-encode fallback returns the raw value when the encoder can't represent it.
    func testMailboxPercentEncodedFallsBackToRawValue() {
        XCTAssertEqual(
            MailboxEndpoint.percentEncoded("abc", allowed: .alphanumerics, encode: { _, _ in nil }),
            "abc")
        XCTAssertEqual(MailboxEndpoint.percentEncoded("a b", allowed: .alphanumerics), "a%20b")
    }

    // Claude JSONL parse edge arms: two distinct models (max comparator), a todo
    // with no status (`?? ""`), and a non-numeric token value (NSNumber path).
    func testSessionActivityClaudeParseEdgeArms() {
        let tail = """
        {"type":"assistant","message":{"model":"claude-opus","id":"m1","usage":{"input_tokens":true,"output_tokens":5},"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"A","status":"completed"},{"content":"B"}]}}]}}
        {"type":"assistant","message":{"model":"claude-sonnet","id":"m2","usage":{"input_tokens":3}}}
        """
        let activity = SessionActivity.parse(claudeJSONLTail: tail)
        XCTAssertEqual(activity.todoTotal, 2)
        XCTAssertEqual(activity.todoDone, 1)        // "B" has no status → not completed
        XCTAssertNotNil(activity.model)             // two models seen → max picked one
        XCTAssertEqual(activity.inputTokens, 4)     // boolean true → NSNumber.intValue 1, plus 3
    }

    // Codex sessions root that is a FILE (not a directory) → the enumerator is
    // nil → recentFiles returns [].
    func testSessionActivityCodexSessionsRootIsFile() throws {
        let codex = tmp.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: codex.appendingPathComponent("sessions").path, contents: Data())
        let reader = SessionActivityReader(homeURL: tmp, maxBytes: 256_000)
        XCTAssertNil(reader.activity(forDirectory: "/x", agentKind: .openAICodex))
    }

    // The DEFAULT group killer (killpg) actually reaps a real own-group child. This exercises
    // the production `groupKiller` + `isAlive` defaults end-to-end: an own-group box past grace
    // → killpg(pid, SIGKILL) tears down the child tree.
    func testProcessIOBoxDefaultKillerSignalsRunningProcess() throws {
        let out = Pipe(), err = Pipe()
        let devNull = open("/dev/null", O_RDWR)
        defer { close(devNull) }
        let spawned = try SpawnInOwnGroup.spawn(
            executablePath: "/bin/sleep",
            arguments: ["sleep", "30"],
            environment: [:],
            stdio: SpawnInOwnGroup.StdioFDs(stdin: devNull, stdout: devNull, stderr: devNull))
        // childInOwnGroup: true → forceKill takes the .killGroup arm with the DEFAULT killpg seam.
        let box = ProcessIOBox(
            pid: spawned.pid,
            stdout: out.fileHandleForReading,
            stderr: err.fileHandleForReading,
            childInOwnGroup: true)
        box.forceKill()
        var status: Int32 = 0
        waitpid(spawned.pid, &status, 0)
        // The child is gone (killpg reaped its own group).
        let gone = kill(spawned.pid, 0) == -1 && errno == ESRCH
        XCTAssertTrue(gone, "default killpg seam must reap the own-group child")
    }

    // modificationDate falls back to .distantPast when the URL's metadata can't
    // be read (e.g. the file no longer exists).
    func testSessionActivityModificationDateFallsBackForUnreadableURL() {
        let missing = tmp.appendingPathComponent("does-not-exist.jsonl")
        XCTAssertEqual(SessionActivityReader(homeURL: tmp).modificationDate(missing), .distantPast)
    }

    // recentFiles over a non-enumerable root yields [] (nil enumerator).
    func testSessionActivityRecentFilesEmptyForMissingRoot() {
        let reader = SessionActivityReader(homeURL: tmp)
        XCTAssertEqual(
            reader.recentFiles(under: tmp, pathExtension: "jsonl", limit: 5, makeEnumerator: { _ in nil }),
            [])
    }

    // intValue coerces a boolean NSNumber; nonEmpty trims to nil when blank.
    func testSessionActivityNumberAndStringHelpers() {
        XCTAssertEqual(SessionActivity.intValue(true), 1)   // Bool → NSNumber path
        XCTAssertEqual(SessionActivity.intValue("nope"), 0)
        XCTAssertNil(SessionActivity.nonEmpty("   \n"))
        XCTAssertEqual(SessionActivity.nonEmpty("  hi "), "hi")
    }

    // A generated agent scaffold whose agentKind is unset but whose command still
    // detects to the preset is recognized (the detect side of the `||`).
    func testBootstrapDetectsGeneratedScaffoldByCommandWhenAgentKindUnset() {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let preset = TerminalAgentPresets.preset(for: .claudeCode)!
        let generated = ProcessEntry(
            projectId: project.id,
            name: preset.displayName,
            kind: .terminalAgent,
            agentKind: nil,                 // first `||` operand false …
            executable: "claude",           // … but the command detects to .claudeCode
            workingDirectory: "/repo",
            lastSummary: "Configured \(preset.displayName) lane"
        )
        let bootstrapped = WorkbenchBootstrapper().bootstrappedState(
            from: WorkspaceState(projects: [project], processEntries: [generated])
        )
        // Untouched generated scaffold (no action log) is pruned.
        XCTAssertFalse(bootstrapped.processEntries.contains { $0.id == generated.id })
    }

    private static func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MailboxStubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

/// In-process transport stub so the real `defaultDataLoader` adapter can be
/// exercised without touching the network.
final class MailboxStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var respond: ((URL) -> (Data, URLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let url = request.url, let (data, response) = Self.respond?(url) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
