import XCTest
@testable import OuroWorkbenchCore

/// Tests for the pure `SessionIdBackfill` seam — the F4 fix. The seam matches a
/// still-id-less RUNNING run to a scanned agent-session record (by harness + cwd,
/// disambiguated by pid) and returns the `runId → sessionId` back-fills to apply.
/// It NEVER overwrites a non-empty id and NEVER hands two distinct runs the same
/// id.
final class SessionIdBackfillTests: XCTestCase {
    // MARK: - Fixtures

    /// A claude terminal-agent entry at `cwd`.
    private func claudeEntry(id: UUID = UUID(), cwd: String) -> ProcessEntry {
        ProcessEntry(
            id: id,
            projectId: UUID(),
            name: "Claude",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "claude",
            arguments: ["--dangerously-skip-permissions"],
            workingDirectory: cwd
        )
    }

    /// A running `ProcessRun` for `entry` with a real pid and no native id yet.
    private func runningRun(id: UUID = UUID(), entry: ProcessEntry, pid: Int32) -> ProcessRun {
        ProcessRun(id: id, entryId: entry.id, pid: pid, status: .running)
    }

    /// A `running:true` scan record keyed on the pid (as `discoverRunning` emits).
    private func runningRecord(harness: AgentHarness, pid: Int32, cwd: String = "") -> AgentSessionRecord {
        AgentSessionRecord(harness: harness, sessionId: "pid-\(pid)", cwd: cwd, running: true)
    }

    /// A `running:false` recent record carrying the NATIVE session id.
    private func recentRecord(
        harness: AgentHarness,
        sessionId: String,
        cwd: String
    ) -> AgentSessionRecord {
        AgentSessionRecord(harness: harness, sessionId: sessionId, cwd: cwd, running: false)
    }

    // MARK: - (a) happy path: one running run, one recent record → back-fill

    func testBackfillsSingleRunningRunFromRecentRecord() {
        let entry = claudeEntry(cwd: "/repo")
        let run = runningRun(entry: entry, pid: 4242)
        let records = [
            runningRecord(harness: .claudeCode, pid: 4242),
            recentRecord(harness: .claudeCode, sessionId: "sess-abc", cwd: "/repo"),
        ]

        let result = SessionIdBackfill.sessionIdBackfills(
            runs: [run], entries: [entry], records: records
        )

        XCTAssertEqual(result, [run.id: "sess-abc"])
    }

    // MARK: - (b) fallback: no matching recent record → no back-fill (stays nil)

    func testNoBackfillWhenNoRecentRecordForCwd() {
        let entry = claudeEntry(cwd: "/repo")
        let run = runningRun(entry: entry, pid: 4242)
        // Live process is observed, but NO recent record carries a native id for
        // this cwd → leave nil so the planner falls back to --continue.
        let records = [runningRecord(harness: .claudeCode, pid: 4242)]

        let result = SessionIdBackfill.sessionIdBackfills(
            runs: [run], entries: [entry], records: records
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testNoBackfillWhenNoLiveProcessRecordForPid() {
        // A recent record exists, but the run's pid is NOT in the running set
        // (process gone / mismatch) → don't pin → no back-fill.
        let entry = claudeEntry(cwd: "/repo")
        let run = runningRun(entry: entry, pid: 4242)
        let records = [
            runningRecord(harness: .claudeCode, pid: 9999),
            recentRecord(harness: .claudeCode, sessionId: "sess-abc", cwd: "/repo"),
        ]

        let result = SessionIdBackfill.sessionIdBackfills(
            runs: [run], entries: [entry], records: records
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testNoBackfillWhenRunHasNilPid() {
        // A run with no pid can't be pinned to a live process → no back-fill.
        let entry = claudeEntry(cwd: "/repo")
        let run = ProcessRun(entryId: entry.id, pid: nil, status: .running)
        let records = [
            recentRecord(harness: .claudeCode, sessionId: "sess-abc", cwd: "/repo"),
        ]

        let result = SessionIdBackfill.sessionIdBackfills(
            runs: [run], entries: [entry], records: records
        )

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - (c) same-cwd disambiguation

    func testTwoSameCwdRunsGetDistinctIdsViaPid() {
        // Two distinct claude entries in the SAME cwd, two live processes. The
        // scan carries a running record per pid AND a recent record per native id
        // (both at /repo — in production `merge` collapses the two recents to one,
        // but this asserts the seam handles the un-collapsed two-record input
        // without ever assigning one id to both runs).
        let entryA = claudeEntry(cwd: "/repo")
        let entryB = claudeEntry(cwd: "/repo")
        let runA = runningRun(entry: entryA, pid: 100)
        let runB = runningRun(entry: entryB, pid: 200)
        let records = [
            runningRecord(harness: .claudeCode, pid: 100),
            runningRecord(harness: .claudeCode, pid: 200),
            recentRecord(harness: .claudeCode, sessionId: "sess-A", cwd: "/repo"),
            recentRecord(harness: .claudeCode, sessionId: "sess-B", cwd: "/repo"),
        ]

        let result = SessionIdBackfill.sessionIdBackfills(
            runs: [runA, runB], entries: [entryA, entryB], records: records
        )

        // Two live runs compete for the same (harness, cwd) → not separable from a
        // pure cwd match → BOTH left nil (honest fallback). The hard invariant:
        // the two runs NEVER receive the same id.
        let ids = Array(result.values)
        XCTAssertEqual(Set(ids).count, ids.count, "two runs must never share an id")
        // Specifically: ambiguous same-cwd pair leaves both unset.
        XCTAssertNil(result[runA.id])
        XCTAssertNil(result[runB.id])
    }

    func testSingleRunPerCwdAcrossTwoCwdsBackfillsEach() {
        // Two runs in DIFFERENT cwds → each is the lone competitor for its cwd →
        // each back-fills to its own native id; the two ids are distinct.
        let entryA = claudeEntry(cwd: "/repoA")
        let entryB = claudeEntry(cwd: "/repoB")
        let runA = runningRun(entry: entryA, pid: 100)
        let runB = runningRun(entry: entryB, pid: 200)
        let records = [
            runningRecord(harness: .claudeCode, pid: 100),
            runningRecord(harness: .claudeCode, pid: 200),
            recentRecord(harness: .claudeCode, sessionId: "sess-A", cwd: "/repoA"),
            recentRecord(harness: .claudeCode, sessionId: "sess-B", cwd: "/repoB"),
        ]

        let result = SessionIdBackfill.sessionIdBackfills(
            runs: [runA, runB], entries: [entryA, entryB], records: records
        )

        XCTAssertEqual(result[runA.id], "sess-A")
        XCTAssertEqual(result[runB.id], "sess-B")
        XCTAssertEqual(Set(result.values).count, 2)
    }

    // MARK: - (d) no-clobber / skip guards

    func testRunWithNonEmptyIdIsAbsentFromMap() {
        let entry = claudeEntry(cwd: "/repo")
        var run = runningRun(entry: entry, pid: 4242)
        run.terminalSessionId = "already-here"
        let records = [
            runningRecord(harness: .claudeCode, pid: 4242),
            recentRecord(harness: .claudeCode, sessionId: "sess-abc", cwd: "/repo"),
        ]

        let result = SessionIdBackfill.sessionIdBackfills(
            runs: [run], entries: [entry], records: records
        )

        XCTAssertNil(result[run.id], "a run that already has an id must not be re-mapped")
        XCTAssertTrue(result.isEmpty)
    }

    func testNonRunningRunIsSkipped() {
        let entry = claudeEntry(cwd: "/repo")
        let run = ProcessRun(entryId: entry.id, pid: 4242, status: .needsRecovery)
        let records = [
            runningRecord(harness: .claudeCode, pid: 4242),
            recentRecord(harness: .claudeCode, sessionId: "sess-abc", cwd: "/repo"),
        ]

        let result = SessionIdBackfill.sessionIdBackfills(
            runs: [run], entries: [entry], records: records
        )

        XCTAssertTrue(result.isEmpty, "only .running runs are back-filled")
    }

    func testRunWithNoEntryIsSkipped() {
        let entry = claudeEntry(cwd: "/repo")
        let orphan = ProcessRun(entryId: UUID(), pid: 4242, status: .running)
        let records = [
            runningRecord(harness: .claudeCode, pid: 4242),
            recentRecord(harness: .claudeCode, sessionId: "sess-abc", cwd: "/repo"),
        ]

        let result = SessionIdBackfill.sessionIdBackfills(
            runs: [orphan], entries: [entry], records: records
        )

        XCTAssertTrue(result.isEmpty, "a run with no matching entry is skipped")
    }

    func testCustomHarnessIsSkipped() {
        // A non-agent (custom) entry: TerminalAgentDetector returns nil → skipped.
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Shell",
            kind: .terminalAgent,
            executable: "fish",
            arguments: [],
            workingDirectory: "/repo"
        )
        let run = runningRun(entry: entry, pid: 4242)
        let records = [
            runningRecord(harness: .custom, pid: 4242),
            recentRecord(harness: .custom, sessionId: "sess-abc", cwd: "/repo"),
        ]

        let result = SessionIdBackfill.sessionIdBackfills(
            runs: [run], entries: [entry], records: records
        )

        XCTAssertTrue(result.isEmpty, ".custom harness has no native resume id to back-fill")
    }

    func testEmptyNativeIdRecordDoesNotBackfill() {
        // A recent record whose sessionId is empty carries nothing to write.
        let entry = claudeEntry(cwd: "/repo")
        let run = runningRun(entry: entry, pid: 4242)
        let records = [
            runningRecord(harness: .claudeCode, pid: 4242),
            recentRecord(harness: .claudeCode, sessionId: "", cwd: "/repo"),
        ]

        let result = SessionIdBackfill.sessionIdBackfills(
            runs: [run], entries: [entry], records: records
        )

        XCTAssertTrue(result.isEmpty, "an empty native id is not a usable back-fill")
    }

    func testCwdMismatchDoesNotBackfill() {
        // Live process pinned, but the only recent record is for a DIFFERENT cwd.
        let entry = claudeEntry(cwd: "/repo")
        let run = runningRun(entry: entry, pid: 4242)
        let records = [
            runningRecord(harness: .claudeCode, pid: 4242),
            recentRecord(harness: .claudeCode, sessionId: "sess-abc", cwd: "/other"),
        ]

        let result = SessionIdBackfill.sessionIdBackfills(
            runs: [run], entries: [entry], records: records
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testHarnessMismatchDoesNotBackfill() {
        // The run is claude; the only recent record at this cwd is codex → no
        // cross-harness back-fill even with a live process record present.
        let entry = claudeEntry(cwd: "/repo")
        let run = runningRun(entry: entry, pid: 4242)
        let records = [
            runningRecord(harness: .claudeCode, pid: 4242),
            recentRecord(harness: .openAICodex, sessionId: "codex-sess", cwd: "/repo"),
        ]

        let result = SessionIdBackfill.sessionIdBackfills(
            runs: [run], entries: [entry], records: records
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testCodexRunBackfillsFromCodexRecord() {
        // Cover the codex harness path end-to-end (distinct rawValue branch).
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            arguments: ["--yolo"],
            workingDirectory: "/repo"
        )
        let run = runningRun(entry: entry, pid: 7000)
        let records = [
            runningRecord(harness: .openAICodex, pid: 7000),
            recentRecord(harness: .openAICodex, sessionId: "codex-123", cwd: "/repo"),
        ]

        let result = SessionIdBackfill.sessionIdBackfills(
            runs: [run], entries: [entry], records: records
        )

        XCTAssertEqual(result, [run.id: "codex-123"])
    }

    func testEmptyInputsReturnEmptyMap() {
        let result = SessionIdBackfill.sessionIdBackfills(runs: [], entries: [], records: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testDuplicateEntryIdKeepsFirstAndStillBackfills() {
        // Two entries sharing an id (degenerate, but must not trap): the lookup
        // keeps the first and the lone run still back-fills normally.
        let sharedId = UUID()
        let first = claudeEntry(id: sharedId, cwd: "/repo")
        let dup = claudeEntry(id: sharedId, cwd: "/repo")
        let run = runningRun(entry: first, pid: 4242)
        let records = [
            runningRecord(harness: .claudeCode, pid: 4242),
            recentRecord(harness: .claudeCode, sessionId: "sess-abc", cwd: "/repo"),
        ]

        let result = SessionIdBackfill.sessionIdBackfills(
            runs: [run], entries: [first, dup], records: records
        )

        XCTAssertEqual(result, [run.id: "sess-abc"])
    }

    func testRunningRecordWithMalformedPidIsIgnored() {
        // A running record whose sessionId is "pid-<garbage>" (has the prefix but
        // no integer) can't pin any run; nothing back-fills.
        let entry = claudeEntry(cwd: "/repo")
        let run = runningRun(entry: entry, pid: 4242)
        let records = [
            AgentSessionRecord(harness: .claudeCode, sessionId: "pid-notanint", cwd: "", running: true),
            recentRecord(harness: .claudeCode, sessionId: "sess-abc", cwd: "/repo"),
        ]

        let result = SessionIdBackfill.sessionIdBackfills(
            runs: [run], entries: [entry], records: records
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testRunningRecordWithoutPidPrefixIsIgnored() {
        // A running record whose sessionId lacks the "pid-" prefix entirely (e.g.
        // a forward-memory-tagged running record carrying a native id) is not a
        // pin source → the run can't be pinned → nothing back-fills.
        let entry = claudeEntry(cwd: "/repo")
        let run = runningRun(entry: entry, pid: 4242)
        let records = [
            AgentSessionRecord(harness: .claudeCode, sessionId: "native-running-id", cwd: "/repo", running: true),
            recentRecord(harness: .claudeCode, sessionId: "sess-abc", cwd: "/repo"),
        ]

        let result = SessionIdBackfill.sessionIdBackfills(
            runs: [run], entries: [entry], records: records
        )

        XCTAssertTrue(result.isEmpty)
    }
}

/// END-TO-END pipeline tests for the F4 back-fill — the regression guard for the
/// HIGH cold-review finding. The pure-seam tests above hand-build the record array
/// and deliberately BYPASS `AgentSessionScanner.merge`. That bypass is exactly what
/// masked the production defect: the App fed `SessionIdBackfill` the MERGE-COLLAPSED
/// records (Phase 2 folds all same-`harness|cwd` running records into one), and
/// because the App's `ps`-backed lister reports `cwd: nil` → every running record
/// lands at `cwd:""` → ALL same-harness live pids collapsed to ONE survivor →
/// multi-agent recovery silently failed while the bypassing unit test stayed green.
///
/// These tests drive the REAL production pipeline — `discoverRunning` (a lister
/// that reports `cwd: nil`, exactly like the App's `ps` lister) + `discoverClaudeRecent`
/// (real on-disk transcripts in DISTINCT cwds) — through the actual records the App
/// now feeds the seam (`backfillRecords`), and assert two same-harness runs in
/// distinct cwds BOTH back-fill. They also pin the negative: the OLD `scan` (merged)
/// source would have dropped a run, so the fix is load-bearing, not cosmetic.
final class SessionIdBackfillPipelineTests: XCTestCase {
    // MARK: - Fixtures

    private func claudeEntry(cwd: String) -> ProcessEntry {
        ProcessEntry(
            projectId: UUID(),
            name: "Claude",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "claude",
            arguments: ["--dangerously-skip-permissions"],
            workingDirectory: cwd
        )
    }

    private func runningRun(entry: ProcessEntry, pid: Int32) -> ProcessRun {
        ProcessRun(entryId: entry.id, pid: pid, status: .running)
    }

    /// Write a Claude transcript on disk under `~/.claude/projects/<dir>/<name>`
    /// so `discoverClaudeRecent` actually parses it (the REAL recent source). The
    /// project dir is derived the same way the scanner expects.
    private func writeClaudeTranscript(home: URL, directory: String, name: String, contents: String) throws {
        let projectDir = home
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(SessionActivityReader.claudeProjectDirName(forDirectory: directory), isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: projectDir.appendingPathComponent(name))
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - The real-pipeline multi-agent proof

    func testTwoSameHarnessRunsInDistinctCwdsBothBackfillThroughRealPipeline() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }

        let cwdA = "/Users/me/repoA"
        let cwdB = "/Users/me/repoB"

        // Two REAL on-disk Claude transcripts, one per cwd, each carrying its own
        // native sessionId — the recent source `discoverClaudeRecent` will parse.
        try writeClaudeTranscript(home: home, directory: cwdA, name: "sess-A.jsonl", contents: """
        {"type":"user","cwd":"\(cwdA)","gitBranch":"main","sessionId":"sess-A","timestamp":"2026-06-19T11:00:00.000Z"}
        """)
        try writeClaudeTranscript(home: home, directory: cwdB, name: "sess-B.jsonl", contents: """
        {"type":"user","cwd":"\(cwdB)","gitBranch":"main","sessionId":"sess-B","timestamp":"2026-06-19T11:00:00.000Z"}
        """)

        // Two live claude processes — DISTINCT pids — and a lister that reports
        // `cwd: nil` for both, exactly like the App's `ps`-backed lister. This is
        // the precise input that, under the display `scan`'s merge, collapses both
        // running records to ONE survivor (same `harness|cwd:""`).
        let lister: @Sendable () -> [RunningProcessLine] = {
            [
                RunningProcessLine(pid: 100, command: "claude --dangerously-skip-permissions", cwd: nil),
                RunningProcessLine(pid: 200, command: "claude --dangerously-skip-permissions", cwd: nil),
            ]
        }

        let entryA = claudeEntry(cwd: cwdA)
        let entryB = claudeEntry(cwd: cwdB)
        let runA = runningRun(entry: entryA, pid: 100)
        let runB = runningRun(entry: entryB, pid: 200)

        // Drive the REAL pipeline the App now uses: the UN-MERGED backfillRecords.
        let scanner = AgentSessionScanner(homeURL: home)
        let records = scanner.backfillRecords(state: nil, processLister: lister)

        let result = SessionIdBackfill.sessionIdBackfills(
            runs: [runA, runB],
            entries: [entryA, entryB],
            records: records
        )

        // The whole point of F4 for the multi-agent case: BOTH back-fill, each to
        // its own native id, through the real scan pipeline — not just the seam in
        // isolation.
        XCTAssertEqual(result[runA.id], "sess-A", "run A must back-fill to its own native id through the real pipeline")
        XCTAssertEqual(result[runB.id], "sess-B", "run B must back-fill to its own native id through the real pipeline")
        XCTAssertEqual(Set(result.values).count, 2, "the two runs must receive distinct ids")
    }

    func testDisplayScanWouldDropARunProvingTheFixIsLoadBearing() throws {
        // The NEGATIVE pin: feed the seam the OLD source (`scan`, merged) with the
        // exact same real on-disk + nil-cwd-lister input. Phase-2 merge collapses
        // both running records to ONE survivor, so the seam's `liveHarnessByPid`
        // holds at most one pid → at most one run can pin → multi-agent recovery is
        // gutted. This documents the defect the fix repairs, and fails LOUDLY if a
        // future change reroutes the back-fill back through `scan`.
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }

        let cwdA = "/Users/me/repoA"
        let cwdB = "/Users/me/repoB"
        try writeClaudeTranscript(home: home, directory: cwdA, name: "sess-A.jsonl", contents: """
        {"type":"user","cwd":"\(cwdA)","gitBranch":"main","sessionId":"sess-A","timestamp":"2026-06-19T11:00:00.000Z"}
        """)
        try writeClaudeTranscript(home: home, directory: cwdB, name: "sess-B.jsonl", contents: """
        {"type":"user","cwd":"\(cwdB)","gitBranch":"main","sessionId":"sess-B","timestamp":"2026-06-19T11:00:00.000Z"}
        """)

        let lister: @Sendable () -> [RunningProcessLine] = {
            [
                RunningProcessLine(pid: 100, command: "claude --dangerously-skip-permissions", cwd: nil),
                RunningProcessLine(pid: 200, command: "claude --dangerously-skip-permissions", cwd: nil),
            ]
        }

        let entryA = claudeEntry(cwd: cwdA)
        let entryB = claudeEntry(cwd: cwdB)
        let runA = runningRun(entry: entryA, pid: 100)
        let runB = runningRun(entry: entryB, pid: 200)

        let scanner = AgentSessionScanner(homeURL: home)
        let mergedRecords = scanner.scan(state: nil, processLister: lister)

        // Prove the premise: the merge really did collapse the two running records
        // (cwd:"") to a single survivor — at most one live pid reaches the seam.
        let liveRunningPids = mergedRecords
            .filter(\.running)
            .compactMap { Int32($0.sessionId.dropFirst("pid-".count)) }
        XCTAssertEqual(liveRunningPids.count, 1, "merge collapses both nil-cwd running records to ONE survivor")

        let result = SessionIdBackfill.sessionIdBackfills(
            runs: [runA, runB],
            entries: [entryA, entryB],
            records: mergedRecords
        )

        // The defect, made concrete: feeding the merged source, at MOST one run
        // back-fills — the other is silently dropped to `--continue`. (Which one
        // survives is merge-order dependent; the load-bearing fact is that the two
        // are NOT both filled, the exact failure the un-merged source repairs.)
        XCTAssertLessThan(
            result.count, 2,
            "the merged display source drops at least one run — this is the gutted multi-agent case the fix repairs"
        )
    }
}
