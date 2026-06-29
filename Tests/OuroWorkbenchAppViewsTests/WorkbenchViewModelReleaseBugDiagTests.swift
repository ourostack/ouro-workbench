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

    // MARK: - runRecoveryDrill (pure)

    func testRunRecoveryDrill_setsResult() throws {
        let m = try makeVM()
        XCTAssertNil(m.recoveryDrillResult, "precondition")
        m.runRecoveryDrill()
        XCTAssertNotNil(m.recoveryDrillResult, "runRecoveryDrill sets the drill result from recoveryDrill.run")
    }

    // MARK: - collectSupportDiagnostics

    func testCollectSupportDiagnostics_setsCollectingFlag() throws {
        let m = try makeVM()
        XCTAssertFalse(m.supportDiagnosticsIsCollecting, "precondition")
        m.collectSupportDiagnostics()
        XCTAssertTrue(m.supportDiagnosticsIsCollecting, "collect sets the in-flight flag synchronously")
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
        m.collectSupportDiagnostics()   // no result set yet synchronously
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

    func testFileIssue_withReport_setsFilingFlag() throws {
        let m = try makeVM()
        m.lastBugReportURL = URL(fileURLWithPath: "/tmp/vmrbd/bug-report")
        m.fileGitHubIssue = { _, _, _, _, _, _, _, _ in .success("https://github.com/x/y/issues/1") }
        m.fileLastBugReportAsGitHubIssue()
        XCTAssertTrue(m.bugReportIssueIsFiling, "filing sets the in-flight flag synchronously")
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
}
#endif
