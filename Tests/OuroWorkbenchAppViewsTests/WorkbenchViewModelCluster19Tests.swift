#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 19 — the apply-body + entry-less-dispatch tail toward the irreducible floor.
///
/// Drives still-uncovered *logic* of larger dispatch decls directly (every machinery seam stubbed):
///   • `applyOnboardingProposal` (`:5787`) — the WHOLE apply-body (5797-5862) the cluster-13/17 pass
///     left behind (only the not-ready + no-proposal guards were covered): the per-group loop, the
///     `groupCreated` flag, `customSessionFactory.makeEntry` success (append + createdEntries +
///     importedGroupNames), the already-present dedup `continue`, the `catch`/`skipped` arm (forced via
///     an empty-working-directory candidate → `CustomTerminalSessionError.emptyWorkingDirectory`), the
///     `save()` persisted fold, `launch(entry)` (seamed), and the `WorkbenchImportApplyResult` build +
///     `lastImportSummary` / `onboardingImportSummaryHasImports`.
///   • `applyBossAction` (`:7765`) entry-less arms — the entry-less authorize-DENY finish arm
///     (7820-7826) + the entry-less boss-dispatch arms (7892-7905: `.requestProviderConfig` /
///     `.verifyProvider` / `.refreshProvider` / `.selectLane` / `.registerWorkbenchMCP` / `.ensureDaemon`
///     / `.reportBug`) the cluster-1 BossActionTests didn't reach. Each dispatches to a start*/present
///     handler (already covered separately) and returns a `finishBossAction(...)` String + records an
///     action-log entry — the dispatch arm + return are what's driven here; the handlers' detached
///     Task bodies stay carved.
///
/// CARVED: the start* handlers' detached remediation Tasks, the live subprocess/notification machinery
/// (all seams stubbed in makeVM).
@MainActor
final class WorkbenchViewModelCluster19Tests: XCTestCase {

    private static let projectId = UUID(uuidString: "C19F1A00-0000-0000-0000-0000000000A1")!
    private static let wsId = UUID(uuidString: "C19F1A00-0000-0000-0000-0000000000B1")!

    private func makeTmp() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmcluster19-\(UUID().uuidString)", isDirectory: true)
    }

    /// Build a hermetic VM with a real on-disk root (so on-disk validations pass). EVERY machinery
    /// seam is faked (the CI-hang lesson).
    private func makeVM(boss: String = "boss") throws -> (WorkbenchViewModel, String) {
        let tmp = makeTmp()
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let root = tmp.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: agentBundles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: boss),
            bossWatchEnabled: false,
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: root.path)],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: [])])
        try WorkbenchStore(paths: paths).save(state)
        let m = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        m.launchTerminalSession = { _ in }
        m.chooseWorkspaceSaveURL = { _ in nil }
        m.chooseWorkspaceOpenURL = { _ in nil }
        m.runCloneAgent = { _ in .launchFailed }
        m.runColdStartHatch = { _ in .launchFailed }
        m.providerCheckRunner = { _, _, _ in nil }
        m.terminateApp = {}
        m.revealFileViewerSelectingURLs = { _ in }
        m.spawnPersistentScreenQuit = { _, _ in }
        m.postNeedsMeNotificationSink = { _, _ in }
        m.postExitNotification = { _, _, _ in }
        return (m, root.path)
    }

    // MARK: - applyOnboardingProposal apply-body

    private func candidate(workingDirectory: String, id: String = "cand") -> RecentSessionCandidate {
        RecentSessionCandidate(
            id: id, source: .shellHistory, agentKind: nil, title: "build",
            workingDirectory: workingDirectory, lastActiveAt: nil,
            resumeCommand: ["echo", "hi"], summary: "s", evidencePaths: [], confidence: 0.9)
    }

    private func proposal(rootPath: String, terminals: [ProposedTerminalImport]) -> WorkbenchImportProposal {
        WorkbenchImportProposal(
            generatedAt: Date(),
            groups: [ProposedWorkbenchGroup(id: "g1", name: "Imported", rootPath: rootPath, terminals: terminals)],
            ignoredCandidates: [])
    }

    private func readyReadiness() -> OnboardingReadiness {
        OnboardingReadiness(state: .ready, headline: "Ready", detail: "", selectedBossName: "boss", repairSteps: [])
    }

    /// The success apply-body: a ready readiness + a proposal with a default-selected terminal whose
    /// candidate has a valid working directory → makeEntry succeeds → the entry is appended, created,
    /// the group recorded, save() persists, launch is seamed, and the import summary reflects 1 created.
    func testApplyOnboardingProposal_success_createsEntryAndRecordsSummary() throws {
        let (m, root) = try makeVM()
        m.onboardingReadiness = readyReadiness()
        let terminal = ProposedTerminalImport(
            id: "t1", candidate: candidate(workingDirectory: root), name: "build", selectedByDefault: true)
        m.onboardingProposal = proposal(rootPath: root, terminals: [terminal])
        let before = m.state.processEntries.count
        let result = m.applyOnboardingProposal()
        XCTAssertEqual(result?.createdCount, 1, "one default-selected terminal is created")
        XCTAssertEqual(m.state.processEntries.count, before + 1, "the created entry is appended")
        XCTAssertEqual(result?.groupNames, ["Imported"], "the group with a created terminal is recorded")
        XCTAssertTrue(result?.persisted == true, "the durable write lands")
        XCTAssertEqual(m.lastImportSummary?.createdCount, 1, "the import summary is published")
        XCTAssertTrue(m.onboardingImportSummaryHasImports, "the has-imports flag reflects the created entry")
        XCTAssertTrue(
            m.state.actionLog.contains { $0.action == "applyOnboardingProposal" && $0.succeeded },
            "a persisted import logs a success applyOnboardingProposal audit")
    }

    /// The skipped/catch arm: a default-selected terminal whose candidate has an EMPTY working
    /// directory → `makeEntry` throws `emptyWorkingDirectory` → the terminal is skipped, no entry is
    /// created, and a non-success audit is logged.
    func testApplyOnboardingProposal_emptyWorkingDir_skipsAndLogsFailure() throws {
        let (m, _) = try makeVM()
        m.onboardingReadiness = readyReadiness()
        let terminal = ProposedTerminalImport(
            id: "t1", candidate: candidate(workingDirectory: ""), name: "broken", selectedByDefault: true)
        m.onboardingProposal = proposal(rootPath: "/tmp/c19-empty", terminals: [terminal])
        let result = m.applyOnboardingProposal()
        XCTAssertEqual(result?.createdCount, 0, "an empty-working-dir terminal creates nothing")
        XCTAssertEqual(result?.skippedNames, ["broken"], "the failed terminal is recorded as skipped")
        XCTAssertTrue(
            m.state.actionLog.contains { $0.action == "applyOnboardingProposal" && !$0.succeeded },
            "a skipped terminal logs a non-success applyOnboardingProposal audit")
    }

    /// The dedup `continue` arm: an already-present entry (same name + project) is skipped without
    /// re-creation or a skip-log.
    func testApplyOnboardingProposal_alreadyPresent_dedupsWithoutRecreating() throws {
        let (m, root) = try makeVM()
        m.onboardingReadiness = readyReadiness()
        // Seed an existing entry that ensureProject will resolve to (the group's rootPath matches Home).
        let existing = ProcessEntry(
            projectId: Self.projectId, name: "build", kind: .shell,
            executable: "/bin/zsh", workingDirectory: root, trust: .trusted)
        m.state.processEntries = [existing]
        // The group rootPath == Home's rootPath → ensureProject returns Home (projectId), so the
        // existing "build" entry collides and the dedup `continue` fires.
        let terminal = ProposedTerminalImport(
            id: "t1", candidate: candidate(workingDirectory: root), name: "build", selectedByDefault: true)
        m.onboardingProposal = WorkbenchImportProposal(
            generatedAt: Date(),
            groups: [ProposedWorkbenchGroup(id: "g1", name: "Home", rootPath: root, terminals: [terminal])],
            ignoredCandidates: [])
        let result = m.applyOnboardingProposal()
        XCTAssertEqual(result?.createdCount, 0, "an already-present terminal is deduped, not re-created")
        XCTAssertEqual(m.state.processEntries.count, 1, "no duplicate entry is appended")
    }

    // MARK: - applyBossAction entry-less dispatch arms

    private func bossAction(_ kind: BossWorkbenchActionKind, name: String? = nil, owner: String? = nil)
        -> BossWorkbenchAction {
        BossWorkbenchAction(action: kind, entry: nil, text: nil, group: nil, name: name,
                            command: nil, workingDirectory: nil, trust: nil, autoResume: nil, owner: owner)
    }

    // NOTE: the entry-less authorize-DENY finish arm (applyBossAction:7820-7826) is defense-in-depth
    // that the upstream `validateForQueueing()` (which name-checks every name-requiring entry-less
    // action FIRST, BossWorkbenchAction.swift:298-320) makes unreachable on the normal path — an
    // empty-name action is rejected at validation before authorize runs. It is therefore CARVED
    // (structurally unreachable), not driven here.

    /// `.requestProviderConfig` dispatches to `openProviderConfig` (allowed entry-less, no name
    /// needed) → presents the form and returns a finishBossAction String.
    func testApplyBossAction_requestProviderConfig_dispatchesAndPresents() throws {
        let (m, _) = try makeVM()
        let result = m.applyBossAction(bossAction(.requestProviderConfig, name: "scout"), source: "boss:x")
        XCTAssertFalse(result.isEmpty, "the entry-less requestProviderConfig dispatch returns a result string")
        XCTAssertTrue(m.isProviderConfigPresented, "requestProviderConfig presents the provider-config form")
    }

    /// `.verifyProvider` with a valid name passes the authorizer and dispatches to `startVerifyProvider`.
    func testApplyBossAction_verifyProvider_validName_dispatches() throws {
        let (m, _) = try makeVM()
        let result = m.applyBossAction(bossAction(.verifyProvider, name: "scout"), source: "boss:x")
        XCTAssertFalse(result.isEmpty, "verifyProvider dispatch returns a result string")
    }

    /// `.refreshProvider` with a valid name dispatches to `startRefreshProvider`.
    func testApplyBossAction_refreshProvider_validName_dispatches() throws {
        let (m, _) = try makeVM()
        let result = m.applyBossAction(bossAction(.refreshProvider, name: "scout"), source: "boss:x")
        XCTAssertFalse(result.isEmpty, "refreshProvider dispatch returns a result string")
    }

    /// `.ensureDaemon` dispatches to `startEnsureDaemon` (machine-scoped, no name needed).
    func testApplyBossAction_ensureDaemon_dispatches() throws {
        let (m, _) = try makeVM()
        let result = m.applyBossAction(bossAction(.ensureDaemon), source: "boss:x")
        XCTAssertFalse(result.isEmpty, "ensureDaemon dispatch returns a result string")
    }

    /// `.reportBug` dispatches to `startReportBug` (known entry-less, no name needed).
    func testApplyBossAction_reportBug_dispatches() throws {
        let (m, _) = try makeVM()
        let result = m.applyBossAction(bossAction(.reportBug), source: "boss:x")
        XCTAssertFalse(result.isEmpty, "reportBug dispatch returns a result string")
    }

    /// `.selectLane` with a valid name dispatches to `startSelectLane`.
    func testApplyBossAction_selectLane_validName_dispatches() throws {
        let (m, _) = try makeVM()
        let result = m.applyBossAction(bossAction(.selectLane, name: "scout"), source: "boss:x")
        XCTAssertFalse(result.isEmpty, "selectLane dispatch returns a result string")
    }

    /// `.registerWorkbenchMCP` with a valid name dispatches to `startRegisterWorkbenchMCP`.
    func testApplyBossAction_registerWorkbenchMCP_validName_dispatches() throws {
        let (m, _) = try makeVM()
        let result = m.applyBossAction(bossAction(.registerWorkbenchMCP, name: "scout"), source: "boss:x")
        XCTAssertFalse(result.isEmpty, "registerWorkbenchMCP dispatch returns a result string")
    }
}
#endif
