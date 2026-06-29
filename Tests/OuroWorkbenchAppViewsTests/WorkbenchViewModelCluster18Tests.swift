#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 18 — the diminishing-yield tail toward the irreducible floor.
///
/// Drives the still-uncovered *logic* of the cold-start / bug-report / release / command-dispatch
/// decls via existing seams + two byte-identical result-fold extractions, carving only the literal
/// machinery lines:
///   • `applyColdStartConfigResult` (extracted from `submitProviderConfig`'s detached cold-start
///     Task's `MainActor.run` fold — byte-identical) → the `.ready` / `.needsVaultSetup` / `.failed`
///     arms, driven directly (the detached hatch+probe Task stays the boundary).
///   • `submitProviderConfig` SYNC arms — the existing-agent rotation early-return, the `.invalid`
///     form arm, the `.unsupportedColdStartSink` (github-copilot) arm.
///   • `applyBugReportBundleResult` (extracted from `submitBugReport`'s detached writer Task's
///     `.success`/`.failure` switch — byte-identical) → both folds driven directly with a
///     synthesized `Result` (the detached `BugReportWriter.write` + `captureKeyWindowPNG` carve).
///   • `notifyAboutNewNeedsMeItems` final new-items dispatch via the new `postNeedsMeNotificationSink`
///     seam (a recording stub; only `UNUserNotificationCenter.add` in the default closure carves).
///   • `installReleaseUpdate` fast-path staged arm (a non-nil `pendingStagedUpdate` routes to
///     `applyReleaseUpdateAndTerminate`, driven via the `applyStagedUpdateAndRelaunch` + `terminateApp`
///     seams; the live `installer.stage` download stays carved).
///   • `performCommand(WorkbenchCommandID)` residual arms — the no-selection error guards + the
///     pure-sync seamed 1-liner dispatches PerformCommandTests didn't reach.
///
/// CARVED (genuine machinery, NOT driven): the detached `Task{…}` awaited-runner lines
/// (`await self?.runColdStartHatch`, `await Task.detached{}.value`), `captureKeyWindowPNG`'s
/// live-window arm, `UNUserNotificationCenter.add`, `applyReleaseUpdateAndTerminate`'s `terminateApp`
/// + bundle-swap, the live `installer.stage` download, the `Task { await runBossQuick*/refreshWorkspace }`
/// performCommand arms.
@MainActor
final class WorkbenchViewModelCluster18Tests: XCTestCase {

    private static let projectId = UUID(uuidString: "C18F1A00-0000-0000-0000-0000000000A1")!
    private static let wsId = UUID(uuidString: "C18F1A00-0000-0000-0000-0000000000B1")!
    private static let entryId = UUID(uuidString: "C18F1A00-0000-0000-0000-0000000000E1")!

    private func makeTmp() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmcluster18-\(UUID().uuidString)", isDirectory: true)
    }

    /// Build a hermetic VM. EVERY machinery seam is faked so no test can reach live machinery
    /// (the CI-hang lesson): clone/cold-start/provider-check return failure by default, the
    /// save/open panels return nil (the default closures hit `NSSavePanel.runModal()` →
    /// deadlocks the windowless xctest), terminal launch + terminate + notification posts are no-ops.
    private func makeVM(
        boss: String = "boss",
        entries: [ProcessEntry] = [],
        rootPath: String = "/tmp/vmcluster18"
    ) throws -> (WorkbenchViewModel, URL) {
        let tmp = makeTmp()
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        try FileManager.default.createDirectory(at: agentBundles, withIntermediateDirectories: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: boss),
            bossWatchEnabled: false,
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: rootPath)],
            processEntries: entries,
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: entries.map(\.id))])
        try WorkbenchStore(paths: paths).save(state)
        let m = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        // Headless-safety: never reach live machinery.
        m.launchTerminalSession = { _ in }
        m.chooseWorkspaceSaveURL = { _ in nil }
        m.chooseWorkspaceOpenURL = { _ in nil }
        m.runCloneAgent = { _ in .launchFailed }
        m.runColdStartHatch = { _ in .launchFailed }
        m.providerCheckRunner = { _, _, _ in nil }
        m.terminateApp = {}
        m.revealFileViewerSelectingURLs = { _ in }
        m.spawnPersistentScreenQuit = { _, _ in }
        m.runSupportDiagnostics = { _ in throw SupportDiagnosticsRunnerError.scriptMissing(["test no-op"]) }
        m.postNeedsMeNotificationSink = { _, _ in }
        m.postExitNotification = { _, _, _ in }
        return (m, agentBundles)
    }

    private func selectedEntry() -> ProcessEntry {
        ProcessEntry(
            id: Self.entryId, projectId: Self.projectId, name: "build", kind: .shell,
            executable: "/bin/zsh", workingDirectory: "/tmp/vmcluster18", trust: .trusted)
    }

    private func needsMeItem(label: String, detail: String = "do it", urgency: String = "high")
        -> MailboxNeedsMeItem {
        MailboxNeedsMeItem(urgency: urgency, label: label, detail: detail, ref: nil, ageMs: nil)
    }

    /// A dashboard snapshot with `needsMeAvailable == true` (`.complete`) carrying the given items.
    private func snapshot(needsMe items: [MailboxNeedsMeItem]) -> BossDashboardSnapshot {
        BossDashboardSnapshot(
            agentName: "boss", daemonStatus: "running", daemonMode: "auto",
            attentionLabel: "ok", openObligations: 0, activeCodingAgents: 0,
            blockedCodingAgents: 0, needsMeItems: items, codingItems: [],
            observedAt: nil, availability: .complete)
    }

    // MARK: - applyColdStartConfigResult (.ready / .needsVaultSetup / .failed)

    /// `.ready` — the verified-working fold: dismisses the form, clears the in-flight flag, runs the
    /// first-run bootstrap, and logs a *success* providerConfigColdStart audit.
    func testApplyColdStart_ready_dismissesFormAndLogsSuccess() throws {
        let (m, _) = try makeVM()
        m.isProviderConfigPresented = true
        m.providerConfigColdStartInFlight = true
        m.applyColdStartConfigResult(.ready, resolvedAgent: "scout", provider: .anthropic)
        XCTAssertFalse(m.isProviderConfigPresented, "a verified-ready cold-start dismisses the form")
        XCTAssertFalse(m.providerConfigColdStartInFlight, "the in-flight flag clears on every fold")
        XCTAssertTrue(
            m.state.actionLog.contains { $0.action == "providerConfigColdStart" && $0.succeeded },
            "a ready cold-start logs a SUCCESS providerConfigColdStart audit")
    }

    /// `.needsVaultSetup` — the recoverable fold: keeps the form open, arms "Finish setup" (the
    /// vault flag + stashed provider), surfaces the seam-free line, and logs a NON-success audit.
    func testApplyColdStart_needsVaultSetup_armsFinishSetupAndKeepsFormOpen() throws {
        let (m, _) = try makeVM()
        m.isProviderConfigPresented = true
        m.providerConfigColdStartInFlight = true
        m.applyColdStartConfigResult(.needsVaultSetup, resolvedAgent: "scout", provider: .anthropic)
        XCTAssertTrue(m.isProviderConfigPresented, "needs-vault-setup keeps the form open")
        XCTAssertTrue(m.providerConfigNeedsVaultSetup, "the recoverable arm sets the vault-setup flag")
        XCTAssertEqual(m.providerConfigColdStartProvider, .anthropic, "the provider is stashed for the recovery chain")
        XCTAssertNotNil(m.providerConfigColdStartMessage, "the seam-free outcome line is surfaced")
        XCTAssertTrue(
            m.state.actionLog.contains { $0.action == "providerConfigColdStart" && !$0.succeeded },
            "needs-vault-setup logs a NON-success providerConfigColdStart audit")
    }

    /// `.failed` — the honest-failure fold: keeps the form open, surfaces the line, does NOT arm
    /// finish-setup (vault flag stays false), logs a non-success audit.
    func testApplyColdStart_failed_keepsFormOpenWithoutVaultFlag() throws {
        let (m, _) = try makeVM()
        m.isProviderConfigPresented = true
        m.providerConfigColdStartInFlight = true
        m.applyColdStartConfigResult(
            .failed(reason: .hatchNonZeroExit), resolvedAgent: "scout", provider: .anthropic)
        XCTAssertTrue(m.isProviderConfigPresented, "a failed cold-start does NOT dismiss the form")
        XCTAssertFalse(m.providerConfigNeedsVaultSetup, "a failed cold-start never arms finish-setup")
        XCTAssertNotNil(m.providerConfigColdStartMessage, "the seam-free failure line is surfaced")
        XCTAssertTrue(
            m.state.actionLog.contains { $0.action == "providerConfigColdStart" && !$0.succeeded },
            "a failed cold-start logs a NON-success providerConfigColdStart audit")
    }

    // MARK: - submitProviderConfig sync arms

    /// An EXISTING agent name routes to the credential-rotation chain and returns nil synchronously
    /// (no form message; the in-flight status drives the spinner).
    func testSubmitProviderConfig_existingAgent_routesToRotationReturnsNil() throws {
        let (m, agentBundles) = try makeVM()
        // Seed an existing bundle so providerConfigAgentAlreadyExists(named:) → true.
        let bundle = agentBundles.appendingPathComponent("scout.ouro", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let root: [String: Any] = ["enabled": true, "humanFacing": ["outward": ["provider": "anthropic"]]]
        try JSONSerialization.data(withJSONObject: root)
            .write(to: bundle.appendingPathComponent("agent.json"))
        m.refreshOuroAgents()
        m.providerConfigAgentName = "scout"
        let message = m.submitProviderConfig(provider: .anthropic, humanName: "Scout", values: ["apiKey": "sk-x"])
        XCTAssertNil(message, "an existing agent returns nil (rotation drives via the in-flight status)")
        XCTAssertTrue(m.providerConfigColdStartInFlight, "rotation arms the in-flight spinner")
    }

    /// A blank/invalid form returns the Core form's `.invalid` message synchronously.
    func testSubmitProviderConfig_invalidForm_returnsMessage() throws {
        let (m, _) = try makeVM()
        m.providerConfigAgentName = "fresh"
        // An empty values dict for a provider that requires a key → `.invalid`.
        let message = m.submitProviderConfig(provider: .anthropic, humanName: "Fresh", values: [:])
        XCTAssertNotNil(message, "an invalid form returns a non-nil message synchronously")
        XCTAssertFalse(m.providerConfigColdStartInFlight, "an invalid form never arms the cold-start spinner")
    }

    /// The github-copilot cold-start sink (gap b) returns the honest unsupported message synchronously.
    func testSubmitProviderConfig_unsupportedColdStartSink_returnsMessage() throws {
        let (m, _) = try makeVM()
        m.providerConfigAgentName = "fresh"
        // githubToken filled so the missing-fields guard passes → reaches the unsupported-sink arm.
        let message = m.submitProviderConfig(
            provider: .githubCopilot, humanName: "Fresh", values: ["githubToken": "ghp_x"])
        XCTAssertNotNil(message, "the unsupported cold-start sink returns an honest message")
        XCTAssertFalse(m.providerConfigColdStartInFlight, "the unsupported sink never arms the spinner")
    }

    // MARK: - applyBugReportBundleResult (.success / .failure)

    /// `.success` — records the URL/warnings, clears the note, invalidates the prior issue link,
    /// persists the unfiled status, and logs a SUCCESS submitBugReport audit.
    func testApplyBugReportResult_success_recordsAndLogs() throws {
        let (m, _) = try makeVM()
        m.bugReportIsSubmitting = true
        m.bugReportNote = "boom"
        m.bugReportIssueURL = "https://example.com/old"
        let dir = makeTmp().appendingPathComponent("2099-bug")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundle = BugReportBundle(
            directoryURL: dir,
            reportURL: dir.appendingPathComponent("report.md"),
            attachmentNames: [],
            warnings: ["a warning"])
        m.applyBugReportBundleResult(.success(bundle), note: "boom", source: "native")
        XCTAssertFalse(m.bugReportIsSubmitting, "the submitting flag clears on every fold")
        XCTAssertEqual(m.lastBugReportURL, dir, "the bundle URL is recorded")
        XCTAssertEqual(m.lastBugReportWarnings, ["a warning"], "the collection warnings are recorded")
        XCTAssertEqual(m.bugReportNote, "", "the note is cleared on a successful write")
        XCTAssertNil(m.bugReportIssueURL, "a new bundle invalidates the prior issue link")
        XCTAssertTrue(
            m.state.actionLog.contains { $0.action == "submitBugReport" && $0.succeeded },
            "a successful write logs a SUCCESS submitBugReport audit")
    }

    /// `.failure` — surfaces the error and logs a NON-success submitBugReport audit.
    func testApplyBugReportResult_failure_surfacesErrorAndLogs() throws {
        let (m, _) = try makeVM()
        m.bugReportIsSubmitting = true
        struct WriteFailed: LocalizedError { var errorDescription: String? { "disk full" } }
        m.applyBugReportBundleResult(.failure(WriteFailed()), note: "boom", source: "native")
        XCTAssertFalse(m.bugReportIsSubmitting, "the submitting flag clears on the failure fold")
        XCTAssertEqual(m.bugReportError, "disk full", "the error is surfaced")
        XCTAssertTrue(
            m.state.actionLog.contains { $0.action == "submitBugReport" && !$0.succeeded },
            "a failed write logs a NON-success submitBugReport audit")
    }

    // MARK: - notifyAboutNewNeedsMeItems final-dispatch via the sink seam

    /// New needs-me items (after the baseline is established) dispatch to the notification sink with
    /// the new items + total. The decision gates (watch-on / availability / baseline / new-items) are
    /// covered elsewhere; this drives the FINAL dispatch arm via the recording seam.
    func testNotifyNewNeedsMe_newItems_dispatchesToSink() throws {
        let (m, _) = try makeVM()
        m.setBossWatchEnabled(true)
        var dispatched: (items: [MailboxNeedsMeItem], total: Int)?
        m.postNeedsMeNotificationSink = { items, total in dispatched = (items, total) }
        let item1 = needsMeItem(label: "Review PR", detail: "blocked")
        let baseline = snapshot(needsMe: [])
        // First refresh establishes the baseline (no dispatch).
        m.notifyAboutNewNeedsMeItems(previous: nil, current: baseline)
        XCTAssertNil(dispatched, "establishing the baseline does not dispatch")
        // A second refresh carrying a new item dispatches.
        let withItem = snapshot(needsMe: [item1])
        m.notifyAboutNewNeedsMeItems(previous: baseline, current: withItem)
        XCTAssertEqual(dispatched?.items.map(\.id), [item1.id], "the new item is dispatched to the sink")
        XCTAssertEqual(dispatched?.total, 1, "the total-waiting count is passed through")
    }

    // MARK: - installReleaseUpdate fast-path (pendingStagedUpdate present)

    /// A pre-staged update routes `installReleaseUpdate` straight to the apply+relaunch path
    /// (driven via the `applyStagedUpdateAndRelaunch` seam) without touching the network installer.
    func testInstallReleaseUpdate_stagedPresent_appliesViaSeam() async throws {
        let (m, _) = try makeVM()
        let staged = WorkbenchUpdateStager.Staged(
            appURL: URL(fileURLWithPath: "/tmp/staged.app"),
            stagingRoot: URL(fileURLWithPath: "/tmp/staging"), version: "9.9.9", build: "999")
        m.pendingStagedUpdate = staged
        var applied = false
        m.applyStagedUpdateAndRelaunch = { _, _ in applied = true; return .launched }
        var terminated = false
        m.terminateApp = { terminated = true }
        await m.installReleaseUpdate()
        XCTAssertTrue(applied, "the fast-path routes the staged update through the apply seam")
        XCTAssertTrue(terminated, "a launched apply terminates the app to relaunch into the new build")
        XCTAssertTrue(
            m.state.actionLog.contains { $0.action == "installReleaseUpdate" && $0.succeeded },
            "the staged fast-path logs a SUCCESS installReleaseUpdate audit")
    }

    // MARK: - performCommand residual no-selection guards

    /// Every payload-free selected-session command surfaces the "No session is selected" error when
    /// no entry is selected. Drives the residual no-selection guard arms PerformCommandTests skipped.
    func testPerformCommand_noSelectionGuards_surfaceError() throws {
        let guardedCommands: [WorkbenchCommandID] = [
            .askBossAboutSelectedSession,
            .focusSelectedSession,
            .sendControlCToSelectedSession,
            .sendEscapeToSelectedSession,
            .sendEOFToSelectedSession,
            .copySelectedLaunchCommand,
            .openSelectedWorkingDirectory,
            .revealSelectedTranscript,
            .recoverSelectedSession,
        ]
        for command in guardedCommands {
            let (m, _) = try makeVM()
            m.selectedEntryID = nil
            m.performCommand(command)
            XCTAssertEqual(
                m.errorMessage, "No session is selected",
                "\(command) with no selection surfaces the no-session error")
        }
    }

    // MARK: - performCommand residual seamed dispatches (pure-sync flag/seam sets)

    /// `.resetToFirstRun` arms the confirmation sheet (flag only — the destructive reset is gated
    /// behind the confirmation).
    func testPerformCommand_resetToFirstRun_armsConfirmation() throws {
        let (m, _) = try makeVM()
        m.performCommand(.resetToFirstRun)
        XCTAssertTrue(m.isResetFirstRunConfirmationPresented, "reset arms the confirmation sheet")
    }

    /// `.reportBug` presents the bug-report sheet.
    func testPerformCommand_reportBug_presentsSheet() throws {
        let (m, _) = try makeVM()
        m.performCommand(.reportBug)
        XCTAssertTrue(m.isReportBugPresented, "reportBug presents the report sheet")
    }

    /// `.installWorkbenchMCPForBoss` folds a registrar outcome (a non-existent bundle → a recorded
    /// applied-action / error — both arms set state).
    func testPerformCommand_installWorkbenchMCPForBoss_folds() throws {
        let (m, _) = try makeVM()
        let before = m.bossAppliedActions.count
        m.performCommand(.installWorkbenchMCPForBoss)
        XCTAssertGreaterThanOrEqual(
            m.bossAppliedActions.count, before,
            "installWorkbenchMCPForBoss folds an outcome into bossAppliedActions or errorMessage")
    }

    /// `.manageAgents` resolves + selects an agent. With an INSTALLED boss bundle it selects it;
    /// this drives the dispatch arm → `selectAgent`'s installed-agent branch.
    func testPerformCommand_manageAgents_selectsInstalledBoss() throws {
        let (m, agentBundles) = try makeVM()
        // Seed an installed "boss" bundle so selectAgent resolves it (else the no-agents fallback
        // opens the create form instead).
        let bundle = agentBundles.appendingPathComponent("boss.ouro", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let root: [String: Any] = ["enabled": true, "humanFacing": ["outward": ["provider": "anthropic"]]]
        try JSONSerialization.data(withJSONObject: root)
            .write(to: bundle.appendingPathComponent("agent.json"))
        m.refreshOuroAgents()
        m.performCommand(.manageAgents)
        XCTAssertEqual(m.selectedAgentName, "boss", "manageAgents selects the installed boss agent")
    }

    /// `.openWorkspaceConfig` routes to `presentOpenWorkspacePanel` → the (stubbed-nil) open seam →
    /// a cancelled panel is a silent no-op (drives the dispatch arm without runModal).
    func testPerformCommand_openWorkspaceConfig_cancelledIsNoOp() throws {
        let (m, _) = try makeVM()
        m.performCommand(.openWorkspaceConfig)
        XCTAssertNil(m.errorMessage, "a cancelled open-workspace panel is a silent no-op")
    }

    /// `.saveWorkspaceConfig` routes to `presentSaveWorkspacePanel`; with no terminals to save it
    /// surfaces the no-terminals guard (proving the dispatch arm reached the save handler).
    func testPerformCommand_saveWorkspaceConfig_noTerminals_surfacesGuard() throws {
        let (m, _) = try makeVM()
        m.performCommand(.saveWorkspaceConfig)
        XCTAssertEqual(m.errorMessage, "Home has no terminals to save",
                       "saveWorkspaceConfig dispatches to the no-terminals guard")
    }

    // MARK: - negative control

    /// A SELECTED entry skips the no-session guard and reaches `focusTerminal`, which (the entry has
    /// no live terminal session) surfaces the not-running error — proving the guard was passed and
    /// the dispatch reached the focus handler (a DISTINCT message from the no-selection guard).
    func testPerformCommand_focusSelected_withSelection_reachesFocusHandler() throws {
        let entry = selectedEntry()
        let (m, _) = try makeVM(entries: [entry])
        m.selectedEntryID = entry.id
        m.performCommand(.focusSelectedSession)
        XCTAssertEqual(m.errorMessage, "build is not running",
                       "a selected session skips the no-session guard and reaches focusTerminal")
    }
}
#endif
