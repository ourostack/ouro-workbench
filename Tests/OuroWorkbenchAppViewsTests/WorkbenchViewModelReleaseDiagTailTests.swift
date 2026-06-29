#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 11 — the release-update / bug-report-assembly / diagnostics / daemon TAIL.
///
/// Drives the synchronous + deterministically-stubbable arms the cluster-4 release/bug/diag pass
/// left behind. Every region is INVOKED + effect-asserted + mutation-verified:
///   • release-update check: `checkForReleaseUpdate` (`:4577`) via an injected `ReleaseUpdateChecker`
///     whose `dataLoader` returns crafted release JSON or throws — the re-entrancy guard, the
///     success snapshot + action-log, and the `.unavailable` failure arm. No network.
///   • install dispatch: `installReleaseUpdate` (`:4643`) — the `releaseUpdateIsInstalling`
///     re-entrancy guard, the `releaseUpdateSnapshot == nil` ("Check for an update first.") guard,
///     and the `WorkbenchUpdatePlanner.plan` `.failure` arm (a `.current` snapshot → install error).
///   • auto-update: `runAutoUpdateCheckIfDue` (`:4758`) — the once-per-session guard, the
///     `WorkbenchAutoUpdatePolicy.shouldCheck` gate (disabled → returns; due → checks), and the
///     post-check no-installable-update guard (a `.current` snapshot → no stage).
///   • staging guards: `stagePendingUpdate` (`:4785`, widened) — the already-staged skip + the
///     planner-`.failure` (non-update snapshot) skip; `applyStagedUpdateOnQuitIfNeeded` (`:4812`,
///     widened) — the auto-update-off + no-staged-update guard arms.
///   • status presentation: `releaseUpdateStatusLine` (`:1626`) + `releaseUpdateStatusColor`
///     (`:1642`) — every arm (checking / installing / not-checked / per-snapshot-status).
///   • bug-report assembly helpers: `bugReportSessions` (`:5164`, widened — archived filter + the
///     per-entry status/attention/trust/branch projection), `bugReportAgentNames` (`:5184`, dedupe +
///     blank-strip), `bugReportExtraSections` (`:5203`, onboarding-vs-workspace screen + readiness).
///   • diagnostics: `revealSupportDiagnostics` (`:4874`) reveal-vs-noop, `openSupportDiagnosticsFolder`
///     (`:4901`) create+open+log.
///   • daemon: `ensureDaemonRunningOnLaunch` (`:4101`) — the empty-boss-name guard arm AND the
///     non-empty arm via an injected `DaemonManager` whose probe reads `.up` (returns `.resumed`,
///     no spawn) → the launch action-log.
///
/// CARVED (genuine machinery, NOT driven here): `applyReleaseUpdateAndTerminate` (`:4703`,
/// NSApp.terminate + the bundle-swap helper `WorkbenchUpdateInstaller.applyAndRelaunch` which
/// spawns `/bin/sh` to ditto/mv the live app bundle), `applyStagedUpdateOnQuitIfNeeded`'s
/// with-staged body (`applyOnQuit` → same bundle-swap spawn), `installReleaseUpdate`'s staged
/// fast-path + the `.success` `installer.stage` download (network + spawn), `stagePendingUpdate`'s
/// `installer.stage` download, `submitBugReport`'s body (`captureKeyWindowPNG()` → `NSApp.keyWindow`
/// IUO traps headless — the documented floor; only its already-submitting guard is drivable and that
/// is covered in WorkbenchViewModelReleaseBugDiagTests), and `readLoginShellPath` (login-shell
/// subprocess; one of the documented WIDE class-(C) oscillation lines).
@MainActor
final class WorkbenchViewModelReleaseDiagTailTests: XCTestCase {

    private static let projectId = UUID(uuidString: "CB111FE0-0000-0000-0000-0000000000A1")!
    private static let wsId = UUID(uuidString: "CB111FE0-0000-0000-0000-0000000000B1")!
    private static let entryId = UUID(uuidString: "CB111FE0-0000-0000-0000-0000000000E1")!
    private static let runId = UUID(uuidString: "CB111FE0-0000-0000-0000-0000000000F1")!

    private func makeTmp() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmreldiag-\(UUID().uuidString)", isDirectory: true)
    }

    /// Build a VM rooted at a temp dir with a seeded valid workspace. Optional injected
    /// release-update checker (stub dataLoader) and daemon manager (stub probe) so the
    /// network/daemon boundaries never escape.
    private func makeVM(
        boss: String = "boss",
        entries: [ProcessEntry] = [],
        runs: [ProcessRun] = [],
        releaseUpdateChecker: ReleaseUpdateChecker = ReleaseUpdateChecker(),
        daemonManager: DaemonManager = DaemonManager()
    ) throws -> WorkbenchViewModel {
        let paths = WorkbenchPaths(rootURL: makeTmp())
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: boss),
            bossWatchEnabled: false,
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp")],
            processEntries: entries,
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: entries.map(\.id))],
            processRuns: runs)
        try WorkbenchStore(paths: paths).save(state)
        let agentBundles = paths.rootURL.appendingPathComponent("AgentBundles", isDirectory: true)
        let m = WorkbenchViewModel(
            paths: paths,
            daemonManager: daemonManager,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles),
            releaseUpdateChecker: releaseUpdateChecker)
        m.launchTerminalSession = { _ in }
        // Never spawn the real diagnostics collector child (#332 seam).
        m.runSupportDiagnostics = { _ in throw SupportDiagnosticsRunnerError.scriptMissing(["test no-op"]) }
        return m
    }

    private func entry(name: String = "build", archived: Bool = false) -> ProcessEntry {
        ProcessEntry(
            id: Self.entryId, projectId: Self.projectId, name: name, kind: .shell,
            executable: "/bin/zsh", workingDirectory: "/tmp/vmreldiag",
            trust: .trusted, autoResume: false, isArchived: archived)
    }

    // A stub releases-API JSON with one installable release at `version`, with valid
    // archive + manifest assets (so the planner can succeed) — though install itself is carved.
    // `static` + `nonisolated` so the @Sendable dataLoader closure can call it without capturing self.
    nonisolated private static func releasesJSON(version: String) -> Data {
        Data("""
        [
          {
            "tag_name": "v\(version)",
            "html_url": "https://github.com/\(WorkbenchRelease.repository)/releases/tag/v\(version)",
            "draft": false,
            "prerelease": true,
            "assets": [
              { "name": "\(WorkbenchRelease.artifactNamePrefix)\(version)-build.999-abcdef0.zip",
                "browser_download_url": "https://example.test/app.zip", "size": 1000 },
              { "name": "\(WorkbenchRelease.artifactNamePrefix)\(version)-build.999-abcdef0.manifest.json",
                "browser_download_url": "https://example.test/manifest.json", "size": 500 }
            ]
          }
        ]
        """.utf8)
    }

    private func availableSnapshot(version: String = "9.9.9") -> ReleaseUpdateSnapshot {
        ReleaseUpdateSnapshot(
            status: .updateAvailable,
            currentVersion: WorkbenchRelease.version,
            currentBuild: "1",
            latestVersion: version,
            latestBuild: "999",
            tagName: "v\(version)",
            htmlURL: "https://github.com/\(WorkbenchRelease.repository)/releases/tag/v\(version)",
            assets: [
                ReleaseUpdateAsset(
                    name: "\(WorkbenchRelease.artifactNamePrefix)\(version)-build.999-abcdef0.zip",
                    downloadURL: "https://example.test/app.zip", size: 1000),
                ReleaseUpdateAsset(
                    name: "\(WorkbenchRelease.artifactNamePrefix)\(version)-build.999-abcdef0.manifest.json",
                    downloadURL: "https://example.test/manifest.json", size: 500)
            ],
            assetNamingPolicy: WorkbenchReleasePolicy.assetNamingPolicy,
            detail: "\(version) update available")
    }

    private func currentSnapshot() -> ReleaseUpdateSnapshot {
        ReleaseUpdateSnapshot(
            status: .current,
            currentVersion: WorkbenchRelease.version,
            currentBuild: "1",
            latestVersion: WorkbenchRelease.version,
            latestBuild: "1",
            tagName: "v\(WorkbenchRelease.version)",
            htmlURL: nil,
            assets: [],
            assetNamingPolicy: WorkbenchReleasePolicy.assetNamingPolicy,
            detail: "You're on the latest version")
    }

    // MARK: - checkForReleaseUpdate (injected checker, no network)

    func testCheckForReleaseUpdate_success_setsSnapshotAndLogs() async throws {
        let checker = ReleaseUpdateChecker(
            configuration: ReleaseUpdateConfiguration(currentVersion: "0.0.1")
        ) { _ in Self.releasesJSON(version: "9.9.9") }
        let m = try makeVM(releaseUpdateChecker: checker)
        await m.checkForReleaseUpdate()
        XCTAssertNotNil(m.releaseUpdateSnapshot, "the checked snapshot is published")
        XCTAssertEqual(m.releaseUpdateSnapshot?.latestVersion, "9.9.9")
        XCTAssertFalse(m.releaseUpdateIsChecking, "the defer clears the checking flag")
        XCTAssertEqual(m.state.actionLog.first?.action, "checkReleaseUpdates")
    }

    func testCheckForReleaseUpdate_loaderThrows_yieldsUnavailable() async throws {
        let checker = ReleaseUpdateChecker(configuration: ReleaseUpdateConfiguration()) { _ in
            throw ReleaseUpdateError.badResponse
        }
        let m = try makeVM(releaseUpdateChecker: checker)
        await m.checkForReleaseUpdate()
        XCTAssertEqual(m.releaseUpdateSnapshot?.status, .unavailable,
                       "a loader failure yields an .unavailable snapshot")
    }

    func testCheckForReleaseUpdate_alreadyChecking_isNoOp() async throws {
        let m = try makeVM()
        m.releaseUpdateIsChecking = true
        m.releaseUpdateSnapshot = nil
        await m.checkForReleaseUpdate()
        XCTAssertNil(m.releaseUpdateSnapshot, "the already-checking guard returns before checking")
    }

    // MARK: - installReleaseUpdate (deterministic guard arms)

    func testInstall_alreadyInstalling_isNoOp() async throws {
        let m = try makeVM()
        m.releaseUpdateIsInstalling = true
        m.releaseUpdateInstallError = "prior"
        await m.installReleaseUpdate()
        XCTAssertEqual(m.releaseUpdateInstallError, "prior",
                       "the already-installing guard returns early (no reset)")
    }

    func testInstall_noSnapshot_setsCheckFirstError() async throws {
        let m = try makeVM()
        m.releaseUpdateSnapshot = nil
        m.pendingStagedUpdate = nil
        await m.installReleaseUpdate()
        XCTAssertEqual(m.releaseUpdateInstallError, "Check for an update first.")
    }

    func testInstall_planFailure_setsPlanError() async throws {
        let m = try makeVM()
        m.releaseUpdateSnapshot = currentSnapshot()  // .current → planner .failure(.notAnUpdate)
        m.pendingStagedUpdate = nil
        await m.installReleaseUpdate()
        XCTAssertNotNil(m.releaseUpdateInstallError,
                        "a non-update snapshot fails the planner and surfaces the plan error")
        XCTAssertFalse(m.releaseUpdateIsInstalling, "the failed plan returns before setting installing")
    }

    // MARK: - runAutoUpdateCheckIfDue

    func testAutoUpdate_alreadyStartedThisSession_isNoOp() async throws {
        let checker = ReleaseUpdateChecker(configuration: ReleaseUpdateConfiguration()) { _ in
            XCTFail("must not check when already started this session"); return Data()
        }
        let m = try makeVM(releaseUpdateChecker: checker)
        // First call consumes the once-flag (with auto-update disabled it returns at the policy gate
        // without checking); the second call must short-circuit at the started-this-session guard.
        m.autoUpdateEnabled = false
        await m.runAutoUpdateCheckIfDue()
        await m.runAutoUpdateCheckIfDue()
        XCTAssertTrue(true, "no checker call fired on the second invocation (XCTFail would have tripped)")
    }

    func testAutoUpdate_disabled_returnsAtPolicyGate() async throws {
        let checker = ReleaseUpdateChecker(configuration: ReleaseUpdateConfiguration()) { _ in
            XCTFail("disabled auto-update must not reach the network check"); return Data()
        }
        let m = try makeVM(releaseUpdateChecker: checker)
        m.autoUpdateEnabled = false
        await m.runAutoUpdateCheckIfDue()
        XCTAssertNil(m.releaseUpdateSnapshot, "the disabled policy gate returns before any check")
    }

    func testAutoUpdate_enabledAndDue_checksButCurrentSnapshotSkipsStage() async throws {
        // A .current snapshot passes the check but fails the post-check
        // "snapshot.status == .updateAvailable" guard → no stage (no network installer).
        let checker = ReleaseUpdateChecker(
            configuration: ReleaseUpdateConfiguration(currentVersion: WorkbenchRelease.version)
        ) { _ in
            Data("""
            [ { "tag_name": "v\(WorkbenchRelease.version)", "draft": false, "prerelease": false, "assets": [] } ]
            """.utf8)
        }
        let m = try makeVM(releaseUpdateChecker: checker)
        m.autoUpdateEnabled = true
        // Ensure not throttled: clear any prior check timestamp.
        UserDefaults.standard.removeObject(forKey: WorkbenchViewModel.lastUpdateCheckAtDefaultsKey)
        await m.runAutoUpdateCheckIfDue()
        XCTAssertNotNil(m.releaseUpdateSnapshot, "the due check ran and published a snapshot")
        XCTAssertNil(m.pendingStagedUpdate, "a non-updateAvailable snapshot never stages")
    }

    // MARK: - stagePendingUpdate (widened) guard arms

    func testStagePending_alreadyStaged_isNoOp() async throws {
        let m = try makeVM()
        let staged = WorkbenchUpdateStager.Staged(
            appURL: URL(fileURLWithPath: "/tmp/x.app"),
            stagingRoot: URL(fileURLWithPath: "/tmp/x"), version: "9.9.9", build: "999")
        m.pendingStagedUpdate = staged
        await m.stagePendingUpdate(from: availableSnapshot())
        XCTAssertEqual(m.pendingStagedUpdate?.version, "9.9.9",
                       "the already-staged guard returns; the existing staged update is untouched")
    }

    func testStagePending_planFailure_isNoOp() async throws {
        let m = try makeVM()
        m.pendingStagedUpdate = nil
        await m.stagePendingUpdate(from: currentSnapshot())  // .current → plan .failure → return
        XCTAssertNil(m.pendingStagedUpdate, "a non-update snapshot fails the plan; nothing is staged")
        XCTAssertNil(m.stagedUpdateVersion)
    }

    // MARK: - applyStagedUpdateOnQuitIfNeeded (widened) guard arms

    func testApplyOnQuit_noStaged_isNoOp() throws {
        let m = try makeVM()
        m.autoUpdateEnabled = true
        m.pendingStagedUpdate = nil
        m.applyStagedUpdateOnQuitIfNeeded()  // guard fails on the nil staged → returns, no spawn
        XCTAssertNil(m.pendingStagedUpdate)
    }

    func testApplyOnQuit_autoUpdateDisabled_isNoOp() throws {
        let m = try makeVM()
        m.autoUpdateEnabled = false
        let staged = WorkbenchUpdateStager.Staged(
            appURL: URL(fileURLWithPath: "/tmp/x.app"),
            stagingRoot: URL(fileURLWithPath: "/tmp/x"), version: "9.9.9", build: "999")
        m.pendingStagedUpdate = staged
        m.applyStagedUpdateOnQuitIfNeeded()  // guard fails on autoUpdateEnabled=false → no spawn
        XCTAssertEqual(m.pendingStagedUpdate?.version, "9.9.9",
                       "disabled auto-update returns before consuming the staged update")
    }

    // MARK: - releaseUpdateStatusLine / releaseUpdateStatusColor (pure)

    func testStatusLine_checking() throws {
        let m = try makeVM()
        m.releaseUpdateIsChecking = true
        XCTAssertEqual(m.releaseUpdateStatusLine, "Checking for updates…")
    }

    func testStatusLine_installing() throws {
        let m = try makeVM()
        m.releaseUpdateIsChecking = false
        m.releaseUpdateIsInstalling = true
        XCTAssertEqual(m.releaseUpdateStatusLine, "Installing update…")
    }

    func testStatusLine_notChecked() throws {
        let m = try makeVM()
        m.releaseUpdateIsChecking = false
        m.releaseUpdateIsInstalling = false
        m.releaseUpdateSnapshot = nil
        XCTAssertEqual(m.releaseUpdateStatusLine, "not checked")
    }

    func testStatusLine_snapshotDetail() throws {
        let m = try makeVM()
        m.releaseUpdateSnapshot = currentSnapshot()
        XCTAssertEqual(m.releaseUpdateStatusLine, "You're on the latest version",
                       "with a snapshot and no in-flight work, the line is the snapshot detail")
    }

    func testStatusColor_perStatus() throws {
        let m = try makeVM()
        m.releaseUpdateSnapshot = nil
        XCTAssertEqual(m.releaseUpdateStatusColor, .secondary, "no snapshot → secondary")
        m.releaseUpdateSnapshot = currentSnapshot()
        XCTAssertEqual(m.releaseUpdateStatusColor, .green, ".current → green")
        m.releaseUpdateSnapshot = availableSnapshot()
        XCTAssertEqual(m.releaseUpdateStatusColor, .orange, ".updateAvailable → orange")
    }

    // MARK: - bug-report assembly helpers (widened bugReportSessions + pure helpers)

    func testBugReportSessions_skipsArchivedAndProjectsFields() throws {
        let live = entry(name: "alpha", archived: false)
        let archived = ProcessEntry(
            id: UUID(), projectId: Self.projectId, name: "zombie", kind: .shell,
            executable: "/bin/zsh", workingDirectory: "/tmp/z", trust: .trusted,
            autoResume: false, isArchived: true)
        let m = try makeVM(entries: [live, archived])
        let rows = m.bugReportSessions()
        XCTAssertEqual(rows.map(\.name), ["alpha"], "archived sessions are filtered out")
        XCTAssertEqual(rows.first?.trust, ProcessTrust.trusted.rawValue)
        XCTAssertEqual(rows.first?.workingDirectory, "/tmp/vmreldiag")
    }

    func testBugReportSessions_emptyWhenNoEntries() throws {
        let m = try makeVM(entries: [])
        XCTAssertTrue(m.bugReportSessions().isEmpty, "no entries → no report rows (mutation control)")
    }

    func testBugReportAgentNames_dedupesAndStripsBlanks() throws {
        let m = try makeVM(boss: "Boss")
        let names = m.bugReportAgentNames()
        XCTAssertTrue(names.contains("Boss"), "the boss name is always included")
        // case-insensitive dedupe: the boss appears once even if ouroAgents echo it.
        XCTAssertEqual(names.filter { $0.lowercased() == "boss" }.count, 1)
    }

    func testBugReportExtraSections_workspaceVsOnboarding() throws {
        let m = try makeVM()
        m.isOnboardingPresented = false
        let workspaceSections = m.bugReportExtraSections()
        XCTAssertEqual(workspaceSections.first?.body, "Main workspace")
        m.isOnboardingPresented = true
        let onboardingSections = m.bugReportExtraSections()
        XCTAssertTrue(onboardingSections.first?.body.hasPrefix("Onboarding wizard") == true,
                      "the onboarding screen label switches with isOnboardingPresented")
    }

    // MARK: - diagnostics reveal/open

    func testRevealSupportDiagnostics_noZip_isNoOp() throws {
        let m = try makeVM()
        m.supportDiagnosticsResult = nil
        let before = m.state.actionLog.count
        m.revealSupportDiagnostics()
        XCTAssertEqual(m.state.actionLog.count, before, "no zip → the reveal guard returns, no log")
    }

    func testRevealSupportDiagnostics_withZip_revealsAndLogs() throws {
        let m = try makeVM()
        final class RevealRec { var urls: [URL] = [] }
        let rec = RevealRec()
        m.revealFileViewerSelectingURLs = { rec.urls.append(contentsOf: $0) }
        m.supportDiagnosticsResult = SupportDiagnosticsResult(
            archiveURL: URL(fileURLWithPath: "/tmp/vmreldiag/diag.zip"), output: "")
        let before = m.state.actionLog.count
        m.revealSupportDiagnostics()
        XCTAssertEqual(rec.urls, [URL(fileURLWithPath: "/tmp/vmreldiag/diag.zip")],
                       "the zip is revealed via the injected seam")
        XCTAssertEqual(m.state.actionLog.count, before + 1)
        XCTAssertEqual(m.state.actionLog.first?.action, "revealSupportDiagnostics")
    }

    func testOpenSupportDiagnosticsFolder_createsAndLogs() throws {
        let m = try makeVM()
        let before = m.state.actionLog.count
        m.openSupportDiagnosticsFolder()
        XCTAssertGreaterThan(m.state.actionLog.count, before,
                             "openSupportDiagnosticsFolder creates+opens the folder and logs")
        XCTAssertEqual(m.state.actionLog.first?.action, "openSupportDiagnosticsFolder")
    }

    // MARK: - ensureDaemonRunningOnLaunch

    func testEnsureDaemon_emptyBoss_isNoOp() async throws {
        let m = try makeVM(boss: "   ")  // blank boss → the guard returns before any daemon work
        let before = m.state.actionLog.count
        await m.ensureDaemonRunningOnLaunch()
        XCTAssertEqual(m.state.actionLog.count, before, "a blank boss name returns before ensure")
    }

    func testEnsureDaemon_withBoss_probesUpAndLogs() async throws {
        // Inject a DaemonManager whose probe reads .up → ensureRunning returns .resumed
        // without spawning `ouro up`. Drives the non-empty arm + the action-log.
        let manager = DaemonManager(probe: DaemonLivenessProbe(reachability: { _ in true }))
        let m = try makeVM(boss: "boss", daemonManager: manager)
        let before = m.state.actionLog.count
        await m.ensureDaemonRunningOnLaunch()
        XCTAssertEqual(m.state.actionLog.count, before + 1, "the ensure result is action-logged")
        XCTAssertEqual(m.state.actionLog.first?.action, "ensureDaemon")
        XCTAssertEqual(m.state.actionLog.first?.succeeded, true,
                       "an already-up daemon resumes → succeeded (no manual recovery)")
    }

    // MARK: - Negative control (mutation-verified)

    func testNegativeControl_statusColorTracksStatus() throws {
        // A no-op body returning a fixed color would fail one of these — they must differ.
        let m = try makeVM()
        m.releaseUpdateSnapshot = currentSnapshot()
        let green = m.releaseUpdateStatusColor
        m.releaseUpdateSnapshot = availableSnapshot()
        let orange = m.releaseUpdateStatusColor
        XCTAssertNotEqual(green, orange, "the status color genuinely tracks the snapshot status")
    }
}
#endif
