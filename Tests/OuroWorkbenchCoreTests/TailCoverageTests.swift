import XCTest
@testable import OuroWorkbenchCore

/// Closes the last small line/region gaps across a set of OuroWorkbenchCore
/// files so the target reaches 100%. Each test targets a specific previously
/// uncovered branch and asserts the real contract of that branch.
final class TailCoverageTests: XCTestCase {

    // ProcessExitStatus: the nil-rawWaitStatus arm (no status to decode).
    func testProcessExitStatusNilWaitStatusHasNoExitCode() {
        let status = ProcessExitStatus(rawWaitStatus: nil)
        XCTAssertNil(status.rawWaitStatus)
        XCTAssertNil(status.exitCode)
    }

    // ProcessExitStatus: a signal-terminated status decodes to no exit code.
    func testProcessExitStatusSignalTerminatedHasNoExitCode() {
        let status = ProcessExitStatus(rawWaitStatus: 15) // low 7 bits != 0 => signalled
        XCTAssertNil(status.exitCode)
    }

    // ShellArgumentEscaper: empty string must become explicit empty quotes.
    func testShellEscaperQuotesEmptyStringExplicitly() {
        XCTAssertEqual(ShellArgumentEscaper.quote(""), "''")
    }

    func testShellEscaperLeavesSafeTokensUnquotedAndQuotesTheRest() {
        XCTAssertEqual(ShellArgumentEscaper.quote("safe-path/to_file.txt"), "safe-path/to_file.txt")
        XCTAssertEqual(ShellArgumentEscaper.quote("a b"), "'a b'")
        XCTAssertEqual(ShellArgumentEscaper.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(ShellArgumentEscaper.commandLine(["git", "commit", "-m", "a b"]),
                       "git commit -m 'a b'")
    }

    // WorkbenchGuide: the Identifiable `id` accessors on the value types.
    func testWorkbenchGuideShortcutAndCapabilityIdentifiers() {
        let shortcut = WorkbenchGuide.Shortcut(keys: "⌘S", summary: "Save")
        XCTAssertEqual(shortcut.id, "⌘S\u{1F}Save")
        let capability = WorkbenchGuide.Capability(tool: "openSession", summary: "Open a session")
        XCTAssertEqual(capability.id, "openSession")
    }

    // SessionActivity: the >= $100 cost label rounds to a whole-dollar amount.
    func testSessionActivityUsdLabelForLargeCostRoundsToWholeDollars() {
        // claude-opus output is $75 / 1M tokens, so 2M output tokens ≈ $150.
        let activity = SessionActivity(outputTokens: 2_000_000, model: "claude-opus")
        XCTAssertEqual(activity.usdLabel, "$150")
    }

    // SessionActivity: todoLabel is nil when there is no todo list.
    func testSessionActivityTodoLabelNilWithoutTodos() {
        XCTAssertNil(SessionActivity(todoTotal: 0).todoLabel)
    }

    // SessionActivity: an unpriced (nil) model yields no cost label.
    func testSessionActivityUsdLabelNilForUnpricedModel() {
        XCTAssertNil(SessionActivity(outputTokens: 100, model: nil).usdLabel)
        XCTAssertNil(SessionPricing.rate(forModel: nil))
    }

    // SessionPricing: when two prefixes match, the longest one wins regardless
    // of table order.
    func testSessionPricingLongestPrefixWins() {
        let broad = SessionPricing.Rate(input: 1, output: 1, cacheRead: 1, cacheWrite: 1)
        let specific = SessionPricing.Rate(input: 9, output: 9, cacheRead: 9, cacheWrite: 9)
        let broadFirst: [(prefix: String, rate: SessionPricing.Rate)] =
            [("claude", broad), ("claude-opus", specific)]
        let specificFirst: [(prefix: String, rate: SessionPricing.Rate)] =
            [("claude-opus", specific), ("claude", broad)]
        XCTAssertEqual(SessionPricing.rate(forModel: "claude-opus-4", in: broadFirst)?.output, 9)
        XCTAssertEqual(SessionPricing.rate(forModel: "claude-opus-4", in: specificFirst)?.output, 9)
    }

    // WorkbenchMCPRegistrationOutcome: the needsManualRecovery passthrough.
    func testMCPRegistrationOutcomeNeedsManualRecoveryFollowsTruth() {
        let manual = WorkbenchMCPRegistrationOutcome(agentName: "slugger", truth: .needsManual, commandAttempted: true)
        XCTAssertTrue(manual.needsManualRecovery)
        let ok = WorkbenchMCPRegistrationOutcome(agentName: "slugger", truth: .registered, commandAttempted: true)
        XCTAssertFalse(ok.needsManualRecovery)
    }

    // WorkbenchWorkspaceConfigLoader: an unreadable existing path (a directory
    // where the config file should be) surfaces as malformedJSON, not a crash.
    func testWorkspaceConfigLoaderUnreadablePathIsMalformedJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wsc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Put a *directory* where .workbench.json is expected: it "exists" but can't be read as data.
        let configPath = dir.appendingPathComponent(WorkbenchWorkspaceConfigLoader.configFileName)
        try FileManager.default.createDirectory(at: configPath, withIntermediateDirectories: true)

        XCTAssertThrowsError(try WorkbenchWorkspaceConfigLoader().load(directoryPath: dir.path)) { error in
            guard case WorkbenchWorkspaceConfigError.malformedJSON = error else {
                return XCTFail("expected .malformedJSON, got \(error)")
            }
        }
    }

    // WorkbenchSessionContext: the boss env var is exported when a boss is set.
    func testSessionContextExportsBossEnvironmentVariable() {
        let context = WorkbenchSessionContext(contextFilePath: nil, group: nil, session: nil, boss: "ouro-boss")
        XCTAssertEqual(context.environmentVariables["OURO_WORKBENCH_BOSS"], "ouro-boss")
        // Empty boss must NOT export the variable.
        let empty = WorkbenchSessionContext(contextFilePath: nil, group: nil, session: nil, boss: "")
        XCTAssertNil(empty.environmentVariables["OURO_WORKBENCH_BOSS"])
    }

    // TranscriptRecorder: a write onto a dead handle is swallowed (non-fatal).
    func testTranscriptRecorderSwallowsWriteFailureOnDeadHandle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("transcript.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let handle = try FileHandle(forWritingTo: url)
        try handle.close() // subsequent writes throw — simulates disk-full / closed-underneath-us
        let recorder = TranscriptRecorder(unsafeHandle: handle, url: url)
        recorder.append(Array("dropped slice".utf8)[...]) // async write throws and is caught
        recorder.close() // sync barrier — guarantees the queued append ran before we assert

        // Contract: the failed append is non-fatal; the recorder survived and closed cleanly.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // WorkbenchCommandDescriptor: keywords default to [] when absent from JSON.
    func testCommandDescriptorDecodesMissingKeywordsAsEmpty() throws {
        let id = WorkbenchCommandID.allCases.first!.rawValue
        let json = """
        {"id":"\(id)","title":"Title","detail":"Detail","systemImage":"gear"}
        """.data(using: .utf8)!
        let descriptor = try JSONDecoder().decode(WorkbenchCommandDescriptor.self, from: json)
        XCTAssertEqual(descriptor.keywords, [])
        XCTAssertNil(descriptor.payload)
    }

    // StartupRecoveryReconciler: with multiple runs per entry the recency
    // comparator runs and the latest run drives the entry's attention.
    func testReconcilerUsesMostRecentRunWhenEntryHasMany() {
        let project = WorkbenchProject(name: "Project", rootPath: "/repo")
        let entry = ProcessEntry(
            projectId: project.id,
            name: "Codex",
            kind: .terminalAgent,
            agentKind: .openAICodex,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        )
        var older = ProcessRun(entryId: entry.id, pid: nil, status: .exited, exitCode: 0)
        older.startedAt = Date(timeIntervalSince1970: 1_000)
        var newer = ProcessRun(entryId: entry.id, pid: 42, status: .running)
        newer.startedAt = Date(timeIntervalSince1970: 2_000)
        let state = WorkspaceState(projects: [project], processEntries: [entry], processRuns: [older, newer])

        let reconciled = StartupRecoveryReconciler().reconcile(state)

        // The most-recent run was in-flight, so it reclassifies to needsRecovery and flags the entry.
        XCTAssertEqual(reconciled.processEntries.first?.attention, .needsBossReview)
    }

    // WorkbenchSessionsRenderer: duplicate project ids dedupe (first wins) and
    // sessions still resolve rather than crashing the group lookup.
    func testSessionSnapshotsHandleDuplicateProjectIds() {
        let sharedId = UUID()
        let first = WorkbenchProject(id: sharedId, name: "First", rootPath: "/a")
        let second = WorkbenchProject(id: sharedId, name: "Second", rootPath: "/b")
        let entry = ProcessEntry(
            projectId: sharedId,
            name: "Session",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "claude",
            workingDirectory: "/a",
            trust: .trusted,
            autoResume: true
        )
        let state = WorkspaceState(projects: [first, second], processEntries: [entry], processRuns: [])

        let snapshots = WorkbenchSessionsRenderer().snapshots(state: state)

        XCTAssertEqual(snapshots.count, 1)
    }
}
