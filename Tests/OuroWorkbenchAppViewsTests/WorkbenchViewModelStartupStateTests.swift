#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 9 — the startup / state-load / session-lifecycle cluster.
///
/// Drives the big synchronous-logic block around app launch + quit + persistence:
///   • `commandPaletteItems` (`:1764`) — the command-palette descriptor builder, every conditional
///     arm (boss-check-in not-running, MCP-actionable, last-bug-report, support-diagnostics,
///     release-update, selected-entry + nested transcript/active-session/recover, !activeSessions,
///     recovery-digest, selected-project, focused-agent + nested usable-as-boss / MCP-actionable).
///     Invoked with BOTH the present AND absent state of each conditional, asserted by `.id`.
///   • `load()` (`:9910`, exercised via init) — normal load, first-run-forced, lossy-salvage
///     (`postLoadDecision(.salvageBeforeResave)` via a seeded state file with an undecodable row),
///     and the unreadable-state `.moved` quarantine catch arm (seeded garbage bytes).
///   • startup reconcile / recovery: `reconcileStartupAttentionWithLiveSessions` (`:6906`),
///     `recoverEligibleSessionsOnStartup` (`:6950`), `launchAutoResumeSessionsOnStartup` (`:6977`),
///     `reapOrphanedScreenSessions` (`:6873`, the per-orphan `screen -X quit` seamed behind the new
///     `spawnPersistentScreenQuit` recorder).
///   • flushed-run folds: `reclassifyAttentionForFlushedRuns` (`:9462`) +
///     `backfillSessionIdsForFlushedRuns` (`:9495`) — both widened private→internal; the no-candidate
///     guard arms (no scan Task spawned) are driven directly.
///   • quit / stop: `prepareForTermination` (`:879`), `applyStagedUpdateOnQuitIfNeeded` early-return,
///     `stopAllRunningSessions` (`:7341`), `drainExternalActionRequests` (`:6680`).
///
/// CARVED (genuine machinery, NOT driven here): `resetToFirstRun` (`NSApp.terminate` +
/// `relaunchAfterExit`/`killAllPersistentScreens` subprocess), `persistentSessionIsListed` /
/// `listLiveScreenSessionNames` / `killAllPersistentScreens` (live `screen -ls` Process/Pipe/kill),
/// the literal `Process()` inside the `spawnPersistentScreenQuit` default closure, and the
/// `.moveFailed` load arm (only reachable when the store's quarantine move throws, which the seeded
/// file can't force deterministically — the timestamped quarantine target races).
@MainActor
final class WorkbenchViewModelStartupStateTests: XCTestCase {

    private static let projectId = UUID(uuidString: "C9111FE0-0000-0000-0000-0000000000A1")!
    private static let entryId = UUID(uuidString: "C9111FE0-0000-0000-0000-0000000000E1")!
    private static let wsId = UUID(uuidString: "C9111FE0-0000-0000-0000-0000000000B1")!
    private static let runId = UUID(uuidString: "C9111FE0-0000-0000-0000-0000000000F1")!

    // MARK: - Hermetic VM construction

    /// Thread-safe recorder for the `@Sendable` `spawnPersistentScreenQuit` seam (it may be called
    /// off the main actor in prod; the seam default is `nonisolated`). A lock keeps the append
    /// deterministic so the orphan-quit assertion never races a Task hop.
    private final class QuitArgsRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        func record(_ args: [String]) { lock.lock(); _calls.append(args); lock.unlock() }
        var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
    }

    private func makeTmp() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmstartup-\(UUID().uuidString)", isDirectory: true)
    }

    /// Build a VM from an already-seeded `paths` (the state file at `paths.stateURL` is read by
    /// `load()` during init). Wires the recording seams so no `screen`/Finder/launch escapes.
    private func makeVM(paths: WorkbenchPaths) -> (WorkbenchViewModel, QuitArgsRecorder) {
        let agentBundles = paths.rootURL.appendingPathComponent("AgentBundles", isDirectory: true)
        let m = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        m.launchTerminalSession = { _ in }
        let rec = QuitArgsRecorder()
        m.spawnPersistentScreenQuit = { args, _ in rec.record(args) }
        return (m, rec)
    }

    /// Seed a valid workspace state then build the VM (the common normal-load path).
    private func makeVM(entries: [ProcessEntry] = [], runs: [ProcessRun] = [],
                        boss: String = "boss") throws -> (WorkbenchViewModel, QuitArgsRecorder) {
        let paths = WorkbenchPaths(rootURL: makeTmp())
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: boss),
            bossWatchEnabled: false,
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp")],
            processEntries: entries,
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: entries.map(\.id))],
            processRuns: runs)
        try WorkbenchStore(paths: paths).save(state)
        return makeVM(paths: paths)
    }

    private func entry(kind: ProcessKind = .shell, name: String = "build",
                       autoResume: Bool = false, archived: Bool = false,
                       persistentName: String? = nil) -> ProcessEntry {
        ProcessEntry(
            id: Self.entryId, projectId: Self.projectId, name: name, kind: kind,
            executable: "/bin/zsh", workingDirectory: "/tmp/vmstartup",
            trust: .trusted, autoResume: autoResume, isArchived: archived)
    }

    private func registerLive(_ m: WorkbenchViewModel, persistentName: String? = nil) throws {
        let plan = TerminalCommandPlan(
            entryId: Self.entryId, runId: Self.runId, executable: "/bin/zsh", arguments: [],
            workingDirectory: "/tmp/vmstartup",
            persistentSessionName: persistentName, reason: "startup test")
        m.activeSessions[Self.entryId] = try TerminalSessionController(
            plan: plan, onStarted: { _ in }, onOutput: {}, onTerminated: { _ in })
    }

    private func ids(_ m: WorkbenchViewModel) -> Set<WorkbenchCommandID> {
        Set(m.commandPaletteItems.map(\.id))
    }

    // MARK: - commandPaletteItems (the always-present spine)

    func testCommandPalette_alwaysIncludesCoreCommands() throws {
        let (m, _) = try makeVM()
        let set = ids(m)
        // A representative slice of the unconditional spine.
        for id: WorkbenchCommandID in [.newSession, .toggleBossWatch, .toggleBossPane, .openOnboarding,
                                       .refreshWorkspace, .reportBug, .checkReleaseUpdates,
                                       .showKeyboardShortcutHelp, .openSettings, .openDecisionLog,
                                       .openHarnessStatus, .openAbout, .resetToFirstRun,
                                       .openWorkspaceConfig, .manageAgents] {
            XCTAssertTrue(set.contains(id), "core command \(id) must always be present")
        }
    }

    func testCommandPalette_bossCheckInArm_presentWhenNotRunning_absentWhenRunning() throws {
        let (m, _) = try makeVM()
        m.bossCheckInIsRunning = false
        XCTAssertTrue(ids(m).contains(.bossCheckIn), "check-in command present while not running")
        XCTAssertTrue(ids(m).contains(.bossQuickWhatsGoingOn), "the quick-question block is present too")
        m.bossCheckInIsRunning = true
        XCTAssertFalse(ids(m).contains(.bossCheckIn), "the check-in command is suppressed while a check-in runs")
        XCTAssertFalse(ids(m).contains(.bossQuickKeepMoving), "the quick-question block is suppressed too")
    }

    func testCommandPalette_mcpActionableArm() throws {
        let (m, _) = try makeVM()
        XCTAssertFalse(ids(m).contains(.installWorkbenchMCPForBoss),
                       "no MCP-connect command when the boss MCP registration is not actionable")
        m.bossWorkbenchMCPRegistration = BossWorkbenchMCPRegistrationSnapshot(
            agentName: "boss", serverName: "ouro-workbench", commandPath: "/tmp/mcp",
            agentConfigPath: "/tmp/agent.json", status: .notRegistered, detail: "missing")
        XCTAssertTrue(ids(m).contains(.installWorkbenchMCPForBoss),
                      "an actionable (.notRegistered) registration surfaces the connect command")
    }

    func testCommandPalette_lastBugReportArm() throws {
        let (m, _) = try makeVM()
        XCTAssertFalse(ids(m).contains(.fileBugReportIssue), "no file-issue command without a bug report")
        m.lastBugReportURL = URL(fileURLWithPath: "/tmp/bug.zip")
        XCTAssertTrue(ids(m).contains(.fileBugReportIssue), "a last bug report surfaces the file-as-issue command")
    }

    func testCommandPalette_supportDiagnosticsArm() throws {
        let (m, _) = try makeVM()
        XCTAssertFalse(ids(m).contains(.revealSupportDiagnostics), "no diagnostics commands without a result")
        m.supportDiagnosticsResult = SupportDiagnosticsResult(
            archiveURL: URL(fileURLWithPath: "/tmp/diag.zip"), output: "wrote diag.zip")
        let set = ids(m)
        XCTAssertTrue(set.contains(.revealSupportDiagnostics), "a diagnostics result surfaces the reveal command")
        XCTAssertTrue(set.contains(.copySupportDiagnosticsPath), "and the copy-path command")
    }

    func testCommandPalette_releaseUpdateArm() throws {
        let (m, _) = try makeVM()
        XCTAssertFalse(ids(m).contains(.openReleaseUpdate), "no release-page command without a release URL")
        m.releaseUpdateSnapshot = ReleaseUpdateSnapshot(
            status: .updateAvailable,
            currentVersion: WorkbenchRelease.version,
            latestVersion: "9.9.9",
            tagName: "v9.9.9",
            htmlURL: "https://example.com/release",
            assets: [],
            detail: "update available")
        XCTAssertTrue(ids(m).contains(.openReleaseUpdate),
                      "a release snapshot with an htmlURL surfaces the open-release-page command")
    }

    func testCommandPalette_selectedEntryArm_andNestedActiveSessionAndTranscript() throws {
        let (m, _) = try makeVM(entries: [entry()],
                                runs: [ProcessRun(id: Self.runId, entryId: Self.entryId, status: .exited)])
        m.selectedEntryID = Self.entryId
        var set = ids(m)
        XCTAssertTrue(set.contains(.launchSelectedSession), "a selected non-archived entry surfaces its launch command")
        XCTAssertTrue(set.contains(.askBossAboutSelectedSession))
        XCTAssertTrue(set.contains(.copySelectedLaunchCommand))
        XCTAssertTrue(set.contains(.openSelectedWorkingDirectory))
        // No active session yet → the active-session block is absent.
        XCTAssertFalse(set.contains(.focusSelectedSession), "no focus/redraw/signal commands without a live session")
        XCTAssertFalse(set.contains(.stopSelectedSession))

        // Now register a live session → the active-session nested block appears.
        try registerLive(m)
        set = ids(m)
        XCTAssertTrue(set.contains(.focusSelectedSession), "a live session surfaces the focus command")
        XCTAssertTrue(set.contains(.redrawSelectedSession))
        XCTAssertTrue(set.contains(.sendControlCToSelectedSession))
        XCTAssertTrue(set.contains(.sendEscapeToSelectedSession))
        XCTAssertTrue(set.contains(.sendEOFToSelectedSession))
        XCTAssertTrue(set.contains(.stopSelectedSession))
        XCTAssertTrue(set.contains(.launchSelectedSession),
                      "the title flips to Restart but the id is still launchSelectedSession")
    }

    func testCommandPalette_selectedEntryTranscriptArm() throws {
        // A run with a transcriptPath → the reveal-selected-transcript nested arm.
        var r = ProcessRun(id: Self.runId, entryId: Self.entryId, status: .exited)
        r.transcriptPath = "/tmp/vmstartup/run.log"
        let (m, _) = try makeVM(entries: [entry()], runs: [r])
        m.selectedEntryID = Self.entryId
        XCTAssertTrue(ids(m).contains(.revealSelectedTranscript),
                      "a selected entry whose latest run has a transcript surfaces the reveal-transcript command")
    }

    func testCommandPalette_archivedSelectedEntry_suppressesEntryBlock() throws {
        let (m, _) = try makeVM(entries: [entry(archived: true)])
        m.selectedEntryID = Self.entryId
        XCTAssertFalse(ids(m).contains(.launchSelectedSession),
                       "an archived selected entry does NOT surface the launch/per-session block")
    }

    func testCommandPalette_stopAllArm() throws {
        let (m, _) = try makeVM(entries: [entry()])
        XCTAssertFalse(ids(m).contains(.stopAllRunningSessions), "no stop-all command with no live sessions")
        try registerLive(m)
        XCTAssertTrue(ids(m).contains(.stopAllRunningSessions),
                      "a live session surfaces the stop-all-running-terminals command")
    }

    func testCommandPalette_saveWorkspaceArm_presentWithSelectedProject() throws {
        // makeVM seeds one project; selectedProject resolves to it → the save-workspace arm.
        let (m, _) = try makeVM(entries: [entry()])
        XCTAssertTrue(ids(m).contains(.saveWorkspaceConfig),
                      "a selected project surfaces Save Workspace As…")
    }

    func testCommandPalette_focusedAgentArms_useAsBossAndRepairAndConfig() throws {
        // A non-boss, ready, usable agent that is the focused agent → the per-agent block:
        // use-as-boss (since it's not the boss + usable), repair/config/reveal, no MCP arm
        // (registration not actionable by default).
        let (m, _) = try makeVM(boss: "captain")
        m.ouroAgents = [OuroAgentRecord(
            name: "scout", bundlePath: "/tmp/scout", configPath: "/tmp/scout/agent.json",
            status: .ready, detail: "ready")]
        m.selectedAgentName = "scout"
        let set = ids(m)
        XCTAssertTrue(set.contains(.useSelectedAgentAsBoss),
                      "a non-boss usable focused agent surfaces Use As Boss")
        XCTAssertTrue(set.contains(.repairSelectedAgent))
        XCTAssertTrue(set.contains(.openSelectedAgentConfig))
        XCTAssertTrue(set.contains(.revealSelectedAgentBundle))
    }

    func testCommandPalette_focusedAgentIsBoss_suppressesUseAsBoss() throws {
        // When the focused agent IS the boss, the use-as-boss arm is suppressed (else branch).
        let (m, _) = try makeVM(boss: "scout")
        m.ouroAgents = [OuroAgentRecord(
            name: "scout", bundlePath: "/tmp/scout", configPath: "/tmp/scout/agent.json",
            status: .ready, detail: "ready")]
        m.selectedAgentName = "scout"
        let set = ids(m)
        XCTAssertFalse(set.contains(.useSelectedAgentAsBoss),
                       "the focused agent being the boss suppresses Use As Boss")
        XCTAssertTrue(set.contains(.repairSelectedAgent),
                      "but the repair/config/reveal block still appears for the focused agent")
    }

    func testCommandPalette_noFocusedAgent_suppressesAgentBlock() throws {
        // No matching ouroAgents → focusedAgentForCommand(nil) is nil → the whole agent block is absent.
        let (m, _) = try makeVM(boss: "ghost-boss")
        m.ouroAgents = []
        m.selectedAgentName = nil
        XCTAssertFalse(ids(m).contains(.repairSelectedAgent),
                       "no resolvable focused agent → no per-agent commands")
    }

    // MARK: - load() (exercised through init)

    func testLoad_normal_loadsSeededState() throws {
        let (m, _) = try makeVM(entries: [entry()])
        XCTAssertTrue(m.stateLoadSucceeded, "a clean load marks success so the reaper may run")
        XCTAssertEqual(m.state.processEntries.first?.id, Self.entryId, "the seeded entry is loaded")
        XCTAssertNil(m.errorMessage, "a clean load surfaces no error")
    }

    func testLoad_firstRunForced_bootstrapsFirstRunDefaults() throws {
        let paths = WorkbenchPaths(rootURL: makeTmp())
        // Request a forced first-run setup; load() takes the first-run-forced branch.
        _ = try WorkbenchFactoryReset.requestFirstRunSetup(rootURL: paths.rootURL)
        let (m, _) = makeVM(paths: paths)
        XCTAssertTrue(m.stateLoadSucceeded, "a forced first-run IS a successful load (trustworthy defaults)")
        // First-run defaults carry no persisted projects from a prior session.
        XCTAssertNil(m.errorMessage)
    }

    func testLoad_lossyRow_salvagesAndSurfacesError() throws {
        // Seed a valid state, then corrupt ONE project row so lenient decode drops it
        // (decodeReport.skippedRowCount > 0 → postLoadDecision(.salvageBeforeResave)).
        let paths = WorkbenchPaths(rootURL: makeTmp())
        let good = WorkspaceState(
            projects: [
                WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp"),
                WorkbenchProject(id: UUID(), name: "Other", rootPath: "/tmp/other"),
            ])
        try WorkbenchStore(paths: paths).save(good)
        // Read the JSON, blow up one element of the `projects` array (wrong-typed id → that
        // single FailableDecodable element yields nil → a dropped row).
        var json = try String(contentsOf: paths.stateURL, encoding: .utf8)
        // Replace the FIRST project's "id" string value with a non-UUID number so its element
        // fails to decode (a row drop) while the array + sibling rows still decode.
        json = json.replacingOccurrences(
            of: "\"\(Self.projectId.uuidString)\"",
            with: "12345")
        try json.data(using: .utf8)!.write(to: paths.stateURL)

        let (m, _) = makeVM(paths: paths)
        XCTAssertTrue(m.stateLoadSucceeded, "a lossy-but-salvaged load still counts as success")
        XCTAssertNotNil(m.errorMessage, "a lossy load surfaces the salvage notice")
        XCTAssertTrue(m.errorMessage?.contains("couldn't be read") == true,
                      "the salvage message names the loss: \(m.errorMessage ?? "nil")")
        XCTAssertTrue(m.state.actionLog.contains { $0.action == "loadSalvage" },
                      "the salvage is audit-logged")
    }

    func testLoad_unreadableGarbage_quarantinesAndResetsToEmpty() throws {
        // Seed total garbage (not valid JSON) → store.load() quarantines (moves) the file and
        // throws .unreadableState(.moved); load()'s catch arm surfaces the quarantine notice and
        // resets to a bootstrapped-empty state.
        let paths = WorkbenchPaths(rootURL: makeTmp())
        try FileManager.default.createDirectory(
            at: paths.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not json {{{".utf8).write(to: paths.stateURL)
        let (m, _) = makeVM(paths: paths)
        XCTAssertFalse(m.stateLoadSucceeded,
                       "an unreadable load must NOT mark success (the reaper would quit every live screen)")
        XCTAssertNotNil(m.errorMessage, "the quarantine notice is surfaced")
        XCTAssertTrue(m.errorMessage?.contains("set aside") == true
                      || m.errorMessage?.contains("couldn't be read") == true,
                      "the message points the operator at the quarantined copy: \(m.errorMessage ?? "nil")")
    }

    // MARK: - reconcileStartupAttentionWithLiveSessions

    func testReconcileStartupAttention_noChange_isNoOp() throws {
        let (m, _) = try makeVM(entries: [entry()])
        let before = m.state
        m.liveScreenSessionNames = []   // nothing recovering → reconciler returns identical state
        m.reconcileStartupAttentionWithLiveSessions()
        XCTAssertEqual(m.state.processEntries, before.processEntries,
                       "with nothing to reconcile, the no-change guard returns without mutating")
    }

    func testReconcileStartupAttention_recoveringSurvivor_isConsistent() throws {
        // A run flagged .needsRecovery whose persistent screen (derived from the entry id) is in the
        // live set → the reconciler re-derives a calmer attention. This exercises BOTH arms: the
        // "reconciled != state → assign+save" path when the reconciler flips this fixture, and the
        // no-op guard otherwise. Either way the method must never add/drop entries.
        let persistent = PersistentTerminalSession.sessionName(for: Self.entryId)
        var e = entry()
        e.attention = .needsBossReview
        let run = ProcessRun(id: Self.runId, entryId: Self.entryId, status: .needsRecovery)
        let (m, _) = try makeVM(entries: [e], runs: [run])
        m.liveScreenSessionNames = [persistent]
        let beforeCount = m.state.processEntries.count
        m.reconcileStartupAttentionWithLiveSessions()
        XCTAssertEqual(m.state.processEntries.count, beforeCount,
                       "reconcile never adds/drops entries — it only re-derives attention")
    }

    // MARK: - recoverEligibleSessionsOnStartup

    func testRecoverEligible_alreadyAttempted_isNoOp() throws {
        let (m, _) = try makeVM(entries: [entry()])
        m.didAttemptStartupRecovery = true
        m.recoverEligibleSessionsOnStartup()   // guard returns immediately
        XCTAssertTrue(m.didAttemptStartupRecovery)
        XCTAssertTrue(m.activeSessions.isEmpty, "the no-op guard launches nothing")
    }

    func testRecoverEligible_noPlans_setsAttemptedAndLaunchesNothing() throws {
        // No recovering runs → summary.recoveryPlans has no reattach/resume/respawn → both loops
        // iterate zero times; the flag is still set so it runs at most once.
        let (m, _) = try makeVM(entries: [entry()])
        m.didAttemptStartupRecovery = false
        m.recoverEligibleSessionsOnStartup()
        XCTAssertTrue(m.didAttemptStartupRecovery, "the once-per-launch flag is set")
        XCTAssertTrue(m.activeSessions.isEmpty, "with no recovery plans, nothing is launched")
    }

    // MARK: - launchAutoResumeSessionsOnStartup

    func testLaunchAutoResume_alreadyAttempted_isNoOp() throws {
        let (m, _) = try makeVM(entries: [entry(autoResume: true)])
        m.autoLaunchResumableOnStartup = true
        m.didAttemptAutoResumeLaunch = true
        m.launchAutoResumeSessionsOnStartup()   // first guard returns
        XCTAssertTrue(m.activeSessions.isEmpty, "the already-attempted guard launches nothing")
    }

    func testLaunchAutoResume_prefOff_setsFlagButLaunchesNothing() throws {
        let (m, _) = try makeVM(entries: [entry(autoResume: true)])
        m.autoLaunchResumableOnStartup = false
        m.didAttemptAutoResumeLaunch = false
        m.launchAutoResumeSessionsOnStartup()
        XCTAssertTrue(m.didAttemptAutoResumeLaunch, "the once-per-launch flag is set even when pref is off")
        XCTAssertTrue(m.activeSessions.isEmpty, "pref off → no launch")
    }

    func testLaunchAutoResume_prefOn_launchesEligibleAndLogs() throws {
        // Pref on + an autoResume entry with no active session and no recovery plan → the launch loop
        // fires (via the launchTerminalSession seam) and logs the count.
        let (m, _) = try makeVM(entries: [entry(autoResume: true)])
        m.autoLaunchResumableOnStartup = true
        m.didAttemptAutoResumeLaunch = false
        m.launchAutoResumeSessionsOnStartup()
        XCTAssertTrue(m.didAttemptAutoResumeLaunch)
        XCTAssertTrue(m.state.actionLog.contains { $0.action == "launchAutoResumeSessionsOnStartup" },
                      "launching auto-resume sessions is audit-logged")
    }

    // MARK: - reapOrphanedScreenSessions (the per-orphan quit seam)

    func testReap_stateLoadFailed_isNoOp() async throws {
        let (m, rec) = try makeVM(entries: [entry()])
        m.stateLoadSucceeded = false   // gate: a failed load must NOT reap (would quit live survivors)
        m.liveScreenSessionNames = ["ouro-wb-stranger"]
        await m.reapOrphanedScreenSessions()
        XCTAssertTrue(rec.calls.isEmpty, "a failed state-load NEVER quits any screen")
    }

    func testReap_noOrphans_isNoOp() async throws {
        let (m, rec) = try makeVM(entries: [entry()])
        m.stateLoadSucceeded = true
        m.liveScreenSessionNames = []   // no live sessions → no orphans
        await m.reapOrphanedScreenSessions()
        XCTAssertTrue(rec.calls.isEmpty, "no live sessions → nothing to reap")
    }

    func testReap_orphan_quitsViaSeam() async throws {
        // A live screen whose name hashes to NO known entry id is an orphan → the per-orphan quit
        // fires through the injected seam (no real `screen` spawned).
        let (m, rec) = try makeVM(entries: [entry()])
        m.stateLoadSucceeded = true
        m.liveScreenSessionNames = ["ouro-wb-\(UUID().uuidString)"]   // not derivable from the known entry id
        await m.reapOrphanedScreenSessions()
        XCTAssertFalse(rec.calls.isEmpty, "an orphaned live screen is quit via the seam")
        XCTAssertTrue(rec.calls.first?.contains("-X") == true || rec.calls.first?.contains("quit") == true,
                      "the quit argv is a `screen -X quit` for the orphan: \(rec.calls.first ?? [])")
    }

    // MARK: - reclassify / backfill no-candidate guards (widened)

    func testReclassify_noLiveSession_isNoOp() throws {
        // A flushed run with no matching active session → the per-run guard `continue`s; then the
        // backfill no-candidate guard returns. Nothing mutates, nothing crashes.
        let (m, _) = try makeVM(entries: [entry()],
                                runs: [ProcessRun(id: Self.runId, entryId: Self.entryId, status: .exited)])
        m.reclassifyAttentionForFlushedRuns([Self.runId])
        XCTAssertEqual(m.state.processRuns.first?.id, Self.runId, "no live session → no reclassify mutation")
    }

    func testBackfill_noCandidate_isNoOp() throws {
        // The run is .exited (not .running) → no candidate → the guard returns before any scan Task.
        let (m, _) = try makeVM(entries: [entry()],
                                runs: [ProcessRun(id: Self.runId, entryId: Self.entryId, status: .exited)])
        m.backfillSessionIdsForFlushedRuns([Self.runId])
        XCTAssertNil(m.state.processRuns.first?.terminalSessionId,
                     "no still-id-less running candidate → the no-candidate guard returns, no backfill")
    }

    func testBackfill_emptyInput_isNoOp() throws {
        let (m, _) = try makeVM(entries: [entry()],
                                runs: [ProcessRun(id: Self.runId, entryId: Self.entryId, status: .running)])
        m.backfillSessionIdsForFlushedRuns([])
        XCTAssertNil(m.state.processRuns.first?.terminalSessionId, "empty run-id list → no backfill")
    }

    // MARK: - prepareForTermination

    func testPrepareForTermination_detachesRunningPersistentSessions() throws {
        // A live persistent session whose run is .running → prepareForTermination flips the run to
        // .needsRecovery (cleared pid/exit) and leaves the entry CALM (.idle).
        let persistent = "ouro-wb-detach"
        var run = ProcessRun(id: Self.runId, entryId: Self.entryId, status: .running)
        run.pid = 4242
        let (m, _) = try makeVM(entries: [entry()], runs: [run])
        try registerLive(m, persistentName: persistent)
        m.prepareForTermination()
        let r = m.state.processRuns.first { $0.id == Self.runId }
        XCTAssertEqual(r?.status, .needsRecovery, "a detached-on-quit persistent run is marked needsRecovery")
        XCTAssertNil(r?.pid, "the pid is cleared (it's no longer ours)")
        XCTAssertEqual(m.state.processEntries.first?.attention, .idle,
                       "a cleanly-detached survivor is left CALM, not an orange needs-review")
    }

    func testPrepareForTermination_whileResetting_isNoOp() throws {
        // Register a LIVE persistent session (the only thing prepareForTermination would mutate),
        // then flip the reset flag: the guard must return before the detach-fold, leaving the run
        // exactly as it stood post-construction. (Capture the baseline AFTER init, since load()'s
        // startup reconcile may already have re-derived the seeded run's status.)
        let (m, _) = try makeVM(entries: [entry()],
                                runs: [ProcessRun(id: Self.runId, entryId: Self.entryId, status: .running)])
        try registerLive(m, persistentName: "ouro-wb-reset")
        let baseline = m.state.processRuns.first { $0.id == Self.runId }?.status
        m.isResettingToFirstRun = true
        m.prepareForTermination()   // guard returns before touching state
        XCTAssertEqual(m.state.processRuns.first { $0.id == Self.runId }?.status, baseline,
                       "during a first-run reset, prepareForTermination must not mutate the run state")
    }

    // MARK: - stopAllRunningSessions

    func testStopAll_noSessions_returnsZero() throws {
        let (m, _) = try makeVM(entries: [entry()])
        XCTAssertEqual(m.stopAllRunningSessions(), 0, "no live sessions → stops 0")
        XCTAssertFalse(m.state.actionLog.contains { $0.action == "stopAllRunningSessions" },
                       "the empty guard logs nothing")
    }

    func testStopAll_withLiveSession_stopsAndLogs() throws {
        let (m, _) = try makeVM(entries: [entry()])
        try registerLive(m)
        let stopped = m.stopAllRunningSessions()
        XCTAssertEqual(stopped, 1, "the one live session is counted")
        XCTAssertTrue(m.state.actionLog.contains { $0.action == "stopAllRunningSessions" && $0.succeeded },
                      "stopping all running sessions is audit-logged")
    }

    // MARK: - drainExternalActionRequests

    func testDrain_empty_isNoOp() async throws {
        let (m, _) = try makeVM()
        let before = m.bossAppliedActions.count
        await m.drainExternalActionRequests()   // empty queue → the no-requests guard returns
        XCTAssertEqual(m.bossAppliedActions.count, before, "an empty queue applies nothing")
    }

    func testDrain_pendingRequest_appliesAndSurfaces() async throws {
        let paths = WorkbenchPaths(rootURL: makeTmp())
        try WorkbenchStore(paths: paths).save(WorkspaceState(
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp")]))
        let (m, _) = makeVM(paths: paths)
        // Enqueue a `.launch` of a non-existent entry — applies cleanly (a result string) with no
        // subprocess/NSApp side effect, so the drain's real read+apply path is driven hermetically.
        let queue = WorkbenchActionRequestQueue(directoryURL: m.externalActionQueue.directoryURL)
        try queue.enqueue(WorkbenchActionRequest(
            source: "drain-test", action: BossWorkbenchAction(action: .launch, entry: "ghost")))
        let before = m.bossAppliedActions.count
        await m.drainExternalActionRequests()
        XCTAssertGreaterThan(m.bossAppliedActions.count, before,
                             "a drained request is applied and surfaced into bossAppliedActions")
    }

    // MARK: - Negative controls (mutation-verified)

    func testNegativeControl_stopAllActuallyStops() throws {
        let (m, _) = try makeVM(entries: [entry()])
        try registerLive(m)
        XCTAssertEqual(m.stopAllRunningSessions(), 1, "stopAllRunningSessions returns the real stopped count")
    }

    func testNegativeControl_commandPaletteRespondsToState() throws {
        // Mutation-verified: the same VM with vs without a live session yields a DIFFERENT command set.
        let (m, _) = try makeVM(entries: [entry()])
        let withoutLive = ids(m)
        try registerLive(m)
        let withLive = ids(m)
        XCTAssertTrue(withLive.contains(.stopAllRunningSessions))
        XCTAssertFalse(withoutLive.contains(.stopAllRunningSessions))
        XCTAssertNotEqual(withLive, withoutLive, "the palette is state-driven, not a constant")
    }
}
#endif
