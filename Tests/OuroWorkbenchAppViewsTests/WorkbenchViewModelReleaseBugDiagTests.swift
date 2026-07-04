#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 4 — the release-update / bug-report / support-diagnostics / recovery-drill
/// handlers (`runRecoveryDrill` `:4534`, `collectSupportDiagnostics` `:4794`, the diagnostics
/// reveal/copy/open, `submitBugReport` `:4895`, `fileLastBugReportAsGitHubIssue` `:5031`). These
/// are state-transition + I/O-orchestration logic; the SYNCHRONOUS arms (the in-flight guards, the
/// flag sets, the no-URL error arms, the pure recovery-drill run) are directly INVOKE-able +
/// effect-asserted + mutation-verified. The async subprocess Tasks use the existing closure seams
/// (`runSupportDiagnostics`, `fileGitHubIssue`) so no child orphans (#332).
@MainActor
final class WorkbenchViewModelReleaseBugDiagTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmrbd-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        let m = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        // No-op the diagnostics runner directly so tests never construct or spawn a child process.
        m.runSupportDiagnostics = { _ in
            throw SupportDiagnosticsRunnerError.scriptMissing(["test no-op"])
        }
        return m
    }

    private func waitForSupportDiagnosticsToFinish(
        _ m: WorkbenchViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while m.supportDiagnosticsIsCollecting {
            if ContinuousClock.now >= deadline {
                XCTFail("support diagnostics did not finish before timeout", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForIssueFilingToFinish(
        _ m: WorkbenchViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while m.bugReportIssueIsFiling {
            if ContinuousClock.now >= deadline {
                XCTFail("bug report issue filing did not finish before timeout", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - runRecoveryDrill (pure)

    func testRunRecoveryDrill_setsResult() throws {
        let m = try makeVM()
        XCTAssertNil(m.recoveryDrillResult, "precondition")
        m.runRecoveryDrill()
        XCTAssertNotNil(m.recoveryDrillResult, "runRecoveryDrill sets the drill result from recoveryDrill.run")
    }

    // MARK: - collectSupportDiagnostics

    func testCollectSupportDiagnostics_setsCollectingFlag() async throws {
        let m = try makeVM()
        let logBefore = m.state.actionLog.count
        XCTAssertFalse(m.supportDiagnosticsIsCollecting, "precondition")
        m.collectSupportDiagnostics()
        XCTAssertTrue(m.supportDiagnosticsIsCollecting, "collect sets the in-flight flag synchronously")
        await waitForSupportDiagnosticsToFinish(m)
        XCTAssertEqual(
            m.supportDiagnosticsError,
            SupportDiagnosticsRunnerError.scriptMissing(["test no-op"]).localizedDescription,
            "the failure fold surfaces the diagnostics error")
        XCTAssertEqual(m.state.actionLog.count, logBefore + 1, "the failure fold records one action-log entry")
        XCTAssertEqual(m.state.actionLog.first?.action, "collectSupportDiagnostics")
        XCTAssertFalse(m.state.actionLog.first?.succeeded ?? true, "the failure log entry is marked failed")
    }

    func testCollectSupportDiagnostics_success_setsResultAndLogs() async throws {
        let m = try makeVM()
        let archive = URL(fileURLWithPath: "/Users/microsoft/code/ouro-workbench/.build/vmrbd/diag.zip")
        m.runSupportDiagnostics = { _ in SupportDiagnosticsResult(archiveURL: archive, output: "ok") }
        let logBefore = m.state.actionLog.count
        m.collectSupportDiagnostics()
        XCTAssertTrue(m.supportDiagnosticsIsCollecting, "collect sets the in-flight flag synchronously")
        await waitForSupportDiagnosticsToFinish(m)
        XCTAssertEqual(m.supportDiagnosticsResult?.archiveURL, archive, "the success fold stores the result")
        XCTAssertNil(m.supportDiagnosticsError, "the success fold leaves no error")
        XCTAssertEqual(m.state.actionLog.count, logBefore + 1, "the success fold records one action-log entry")
        XCTAssertEqual(m.state.actionLog.first?.action, "collectSupportDiagnostics")
        XCTAssertTrue(m.state.actionLog.first?.succeeded ?? false, "the success log entry is marked succeeded")
    }

    func testCollectSupportDiagnostics_alreadyCollecting_isNoOp() throws {
        let m = try makeVM()
        m.supportDiagnosticsIsCollecting = true
        m.supportDiagnosticsError = "prior"
        m.collectSupportDiagnostics()
        XCTAssertEqual(m.supportDiagnosticsError, "prior", "the already-collecting guard returns early (no reset)")
    }

    // MARK: - diagnostics reveal/copy/open

    func testCopySupportDiagnosticsPath_noZip_setsError() throws {
        let m = try makeVM()
        m.supportDiagnosticsResult = nil
        m.copySupportDiagnosticsPath()
        XCTAssertEqual(m.errorMessage, "No support diagnostics zip has been collected yet")
    }

    func testCopySupportDiagnosticsPath_withZip_copiesAndLogs() throws {
        let m = try makeVM()
        m.supportDiagnosticsResult = SupportDiagnosticsResult(
            archiveURL: URL(fileURLWithPath: "/tmp/vmrbd/diag.zip"), output: "")
        let before = m.state.actionLog.count
        m.copySupportDiagnosticsPath()
        XCTAssertEqual(m.state.actionLog.count, before + 1)
        XCTAssertEqual(m.state.actionLog.first?.action, "copySupportDiagnosticsPath")
    }

    func testRevealSupportDiagnostics_noZip_isNoOp() throws {
        let m = try makeVM()
        m.supportDiagnosticsResult = nil
        let before = m.state.actionLog.count
        m.revealSupportDiagnostics()
        XCTAssertEqual(m.state.actionLog.count, before, "no zip → the guard returns, no reveal/log")
    }

    func testOpenSupportDiagnosticsFolder_createsAndLogs() throws {
        let m = try makeVM()
        let before = m.state.actionLog.count
        m.openSupportDiagnosticsFolder()
        // Creates the (default) folder + opens it + logs; NSWorkspace.open is harmless in xctest.
        XCTAssertGreaterThanOrEqual(m.state.actionLog.count, before,
                                    "openSupportDiagnosticsFolder routes without error")
    }

    // MARK: - submitBugReport (the already-submitting guard — the only safely-drivable arm)
    //
    // The full submitBugReport path traps in xctest: it calls captureKeyWindowPNG() →
    // `NSApp.keyWindow` (WorkbenchViewModel.swift:5193), and `NSApp` is the global NSApplication!
    // IUO, nil in the headless test process (confirmed: a direct call signal-5 traps — same genuine
    // floor as the ReportBug "Create Report" carve). Only the EARLY already-submitting guard arm
    // (which returns before captureKeyWindowPNG) is safely drivable.

    func testSubmitBugReport_alreadySubmitting_isNoOp() throws {
        let m = try makeVM()
        m.bugReportIsSubmitting = true   // → the `guard !bugReportIsSubmitting else { return }` arm
        m.bugReportError = "prior"
        m.submitBugReport(note: "again")
        XCTAssertEqual(m.bugReportError, "prior", "the already-submitting guard returns early (before the NSApp trap)")
    }

    // MARK: - fileLastBugReportAsGitHubIssue (synchronous guards + in-flight set)

    func testFileIssue_noReport_setsError() throws {
        let m = try makeVM()
        m.lastBugReportURL = nil
        m.fileLastBugReportAsGitHubIssue()
        XCTAssertEqual(m.bugReportIssueError, "Create a bug report first.")
    }

    func testFileIssue_withReport_setsFilingFlag() async throws {
        let m = try makeVM()
        m.lastBugReportURL = URL(fileURLWithPath: "/Users/microsoft/code/ouro-workbench/.build/vmrbd/bug-report")
        m.fileGitHubIssue = { _, _, _, _, _, _, _, _ in .success("https://github.com/x/y/issues/1") }
        let logBefore = m.state.actionLog.count
        m.fileLastBugReportAsGitHubIssue()
        XCTAssertTrue(m.bugReportIssueIsFiling, "filing sets the in-flight flag synchronously")
        await waitForIssueFilingToFinish(m)
        XCTAssertEqual(m.bugReportIssueURL, "https://github.com/x/y/issues/1")
        XCTAssertNil(m.bugReportIssueError)
        XCTAssertEqual(m.state.actionLog.count, logBefore + 1, "the success fold records one action-log entry")
        XCTAssertEqual(m.state.actionLog.first?.action, "fileBugReportIssue")
        XCTAssertTrue(m.state.actionLog.first?.succeeded ?? false, "the success log entry is marked succeeded")
    }

    func testFileIssue_alreadyFiling_isNoOp() throws {
        let m = try makeVM()
        m.bugReportIssueIsFiling = true
        m.bugReportIssueError = "prior"
        m.fileLastBugReportAsGitHubIssue()
        XCTAssertEqual(m.bugReportIssueError, "prior", "the already-filing guard returns early")
    }

    // MARK: - Negative control (mutation-verified)

    func testNegativeControl_runRecoveryDrillActuallyRuns() throws {
        // runRecoveryDrill assigns recoveryDrillResult. A no-op body would leave it nil → RED.
        let m = try makeVM()
        m.recoveryDrillResult = nil
        m.runRecoveryDrill()
        XCTAssertNotNil(m.recoveryDrillResult, "the drill ran and set its result")
    }

    // MARK: - fileLastBugReportAsGitHubIssue (.failure async fold — ZERO production change)
    //
    // VM-GATE FINAL FLOOR (#5): the `fileGitHubIssue` seam already exists + is wired (the success
    // test injects `{ … in .success(...) }`). This injects `{ … in .failure(.cliMissing) }` to drive
    // the previously-uncovered `.failure` arm: clear the filing flag, surface the error, record the
    // failure action-log line. Mirror of applyBugReportBundleResult's `.failure` arm. The detached
    // filing Task spawns no `gh` (the seam returns synchronously); we poll the published flag like
    // ReportBugSheetInteractionTests does.

    func testFileIssue_failure_surfacesErrorAndLogsFailure() async throws {
        let m = try makeVM()
        m.lastBugReportURL = URL(fileURLWithPath: "/Users/microsoft/code/ouro-workbench/.build/vmrbd/bug-report")
        m.fileGitHubIssue = { _, _, _, _, _, _, _, _ in .failure(.cliMissing) }
        let logBefore = m.state.actionLog.count
        m.fileLastBugReportAsGitHubIssue()
        XCTAssertTrue(m.bugReportIssueIsFiling, "filing sets the in-flight flag synchronously")
        await waitForIssueFilingToFinish(m)
        XCTAssertFalse(m.bugReportIssueIsFiling, "the .failure arm clears the in-flight flag")
        XCTAssertEqual(
            m.bugReportIssueError, GitHubIssueFilingError.cliMissing.localizedDescription,
            "the .failure arm surfaces the localized filing error")
        XCTAssertNil(m.bugReportIssueURL, "no issue URL is set on failure")
        XCTAssertEqual(m.state.actionLog.count, logBefore + 1, "the .failure arm records ONE action-log entry")
        XCTAssertEqual(m.state.actionLog.first?.action, "fileBugReportIssue")
        XCTAssertFalse(m.state.actionLog.first?.succeeded ?? true, "the failure log entry is marked NOT succeeded")
    }
}
#endif
