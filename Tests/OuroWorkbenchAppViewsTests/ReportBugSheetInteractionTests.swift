#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B9 — `ReportBugSheet` (`:2429`) INTERACTION drive-to-100%.
///
/// The C5 `ReportBugSheet*StateSetTests` snapshot the RENDER arms (the empty form,
/// the success result box, the issue-URL / issue-error gates) but never EXECUTE the
/// button action-closures — so 9 region segments (the Cancel button, the success
/// box's Reveal-in-Finder / Copy-Path / File-as-GitHub-Issue / Open-Issue buttons,
/// the always-present Open-Reports-Folder + Create-Report buttons) were never
/// coloured. ViewInspector 0.10.3 invokes button actions (`.tap()`), so this suite
/// DRIVES every reachable region and asserts the model side-effect (provenance),
/// mutation-verified.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` (AN-001). The success-box
/// buttons render only when `lastBugReportURL`/`bugReportIssueURL` are set — the SAME
/// `@Published` the live submit / file-as-issue flows set (the C5 direct-injection
/// production seam). Each model method is non-blocking under test: the Finder/issue
/// reveals are `NSWorkspace` calls (no modal), `copyBugReportPath` is a pasteboard
/// write, `fileLastBugReportAsGitHubIssue`/`submitBugReport` set their in-flight flag
/// synchronously and dispatch the heavy work to a detached `Task` (so the tapped
/// action region executes without blocking).
///
/// **#332 subprocess seam.** `fileLastBugReportAsGitHubIssue`'s detached task shells out to
/// `gh issue create`. Under an in-process tap that child OUTLIVES the test and orphans past
/// teardown — crashing CI's xctest at teardown (signal 1). `savedModel()` injects a stub
/// `model.fileGitHubIssue` returning a canned issue URL, so the tap drives the body + the
/// `.success` completion handler with NO real subprocess. Production is byte-identical (the
/// default closure is `GitHubIssueFiler.file`).
///
/// **Carve (genuinely-unreachable):** the "Create Report" button's action
/// `{ model.submitBugReport() }` (`:2579`). `submitBugReport` synchronously calls
/// `captureKeyWindowPNG()`, which force-touches `NSApp.keyWindow` — and `NSApp` is
/// the live `NSApplication!` IUO, which is nil in the `xctest` process (no running
/// app), so tapping the button traps. This is a live-AppKit dependency with no
/// inject seam (the same class as HeaderView's `NSOpenPanel().runModal()` carve).
/// Recorded in `b9-records.md`. Every other region is driven.
@MainActor
final class ReportBugSheetInteractionTests: XCTestCase {

    private static let fixedBundleURL = URL(
        fileURLWithPath: "/tmp/u4/bug-reports/bug-report-2026-06-25-000000", isDirectory: true)
    // `nonisolated` so the #332 `@Sendable` stub closure (savedModel's `fileGitHubIssue`) can
    // reference the canned URL; a `String` literal constant is trivially `Sendable`.
    private nonisolated static let fixedIssueURL = "https://github.com/example/repo/issues/42"

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b9reportbug-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    /// A model with a saved bundle (the `if let url = lastBugReportURL` success box open).
    ///
    /// #332 seam: inject a stub `fileGitHubIssue` so the "File as GitHub Issue" tap fires the
    /// action's synchronous body + the `Task.detached` completion wiring WITHOUT shelling out to
    /// `gh`. Without this, the detached filing task spawns a real `gh issue create` child that
    /// outlives the in-process test and orphans past teardown — crashing CI's xctest at teardown
    /// (signal 1). The stub returns a canned issue URL so the completion handler is exercised too.
    private func savedModel() throws -> WorkbenchViewModel {
        let model = try makeVM()
        model.lastBugReportURL = Self.fixedBundleURL
        model.lastBugReportWarnings = []
        model.fileGitHubIssue = { _, _, _, _, _, _, _, _ in .success(Self.fixedIssueURL) }
        return model
    }

    // MARK: - Cancel button (`:2444`)

    /// `Button("Cancel") { dismiss() }` — a pure environment dismiss.
    func testReportBug_cancelButton_tapRunsDismiss() throws {
        let model = try makeVM()
        try ReportBugSheet(model: model).inspect().find(button: "Cancel").tap()
    }

    // MARK: - Success-box buttons (`:2509`, `:2515`, `:2522`)

    /// "Reveal in Finder" `Button { model.revealLastBugReport() }` (`:2509`). Reveals the
    /// saved bundle via `NSWorkspace.activateFileViewerSelecting` (no modal).
    func testReportBug_revealButton_tapRunsReveal() throws {
        let model = try savedModel()
        try ReportBugSheet(model: model).inspect().find(button: "Reveal in Finder").tap()
    }

    /// "Copy Path" `Button { model.copyBugReportPath() }` (`:2515`). Writes the bundle
    /// path to the pasteboard; assert the path landed there (provenance).
    func testReportBug_copyPathButton_tapCopiesPath() throws {
        let model = try savedModel()
        NSPasteboard.general.clearContents()
        try ReportBugSheet(model: model).inspect().find(button: "Copy Path").tap()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), Self.fixedBundleURL.path,
                       "tapping Copy Path writes the bundle path to the pasteboard")
    }

    /// "File as GitHub Issue" `Button { model.fileLastBugReportAsGitHubIssue() }` (`:2522`).
    /// Renders only while `bugReportIssueURL == nil`. Tapping sets the in-flight flag
    /// synchronously (the heavy filing work is detached). The injected stub (see
    /// `savedModel()`) returns a canned issue URL so the detached task completes WITHOUT
    /// shelling out to `gh` — exercising both the synchronous body and, after the detached
    /// `Task` resolves, the `.success` completion handler (no orphan, #332).
    func testReportBug_fileIssueButton_tapStartsFiling() throws {
        let model = try savedModel()
        XCTAssertNil(model.bugReportIssueURL, "precondition: not yet filed → the file button shows")
        XCTAssertFalse(model.bugReportIssueIsFiling, "precondition: not filing")
        try ReportBugSheet(model: model).inspect().find(button: "File as GitHub Issue").tap()
        XCTAssertTrue(model.bugReportIssueIsFiling,
                      "tapping File as GitHub Issue flips bugReportIssueIsFiling synchronously")
    }

    /// The detached filing task drives the `.success` completion handler to its terminal state:
    /// the canned issue URL lands in `bugReportIssueURL` and the in-flight flag clears. Awaiting
    /// the published transition (no real subprocess, #332 stub) asserts the WHOLE action — body
    /// plus completion — is covered, not just the synchronous prefix.
    func testReportBug_fileIssueButton_completionLandsCannedURL() async throws {
        let model = try savedModel()
        try ReportBugSheet(model: model).inspect().find(button: "File as GitHub Issue").tap()
        // Yield until the detached stub-filing Task resolves and updates the @Published state.
        for _ in 0..<200 where model.bugReportIssueIsFiling { await Task.yield() }
        XCTAssertFalse(model.bugReportIssueIsFiling, "the filing completes (the in-flight flag clears)")
        XCTAssertEqual(model.bugReportIssueURL, Self.fixedIssueURL,
                       "the .success completion handler stores the canned issue URL")
    }

    // MARK: - Open Issue button

    /// "Open Issue" `Button { model.openLastBugReportIssue() }` — renders only when an
    /// issue URL is set. Opens the issue via `NSWorkspace.open` (no modal).
    func testReportBug_openIssueButton_tapRunsOpen() throws {
        let model = try savedModel()
        model.bugReportIssueURL = Self.fixedIssueURL
        try ReportBugSheet(model: model).inspect().find(button: "Open Issue").tap()
    }

    // MARK: - Filing-in-progress ProgressView arm (`:2530`, `:2533`)

    /// The `if model.bugReportIssueIsFiling { ProgressView() }` render arm. With a saved
    /// bundle AND `bugReportIssueIsFiling == true`, the in-flight spinner renders — the
    /// TRUE arm of the filing gate (the file-as-issue button also goes `.disabled`).
    func testReportBug_filingInProgress_rendersProgressView() throws {
        let model = try savedModel()
        model.bugReportIssueIsFiling = true
        XCTAssertTrue(model.bugReportIssueIsFiling, "provenance: a filing is in flight")
        // ViewInspector finds the in-flight `ProgressView` (the `if bugReportIssueIsFiling`
        // TRUE arm). A negative-control (`isFiling == false`) has NO such node — see below.
        let view = ReportBugSheet(model: model)
        XCTAssertNoThrow(try view.inspect().find(ViewType.ProgressView.self),
                         "the filing-in-progress arm renders a ProgressView")
    }

    /// Negative control (P2) for the filing-in-progress gate: with `bugReportIssueIsFiling
    /// == false` the success box renders NO `ProgressView`; flipping it true adds one.
    func testReportBug_negativeControl_filingGateAddsProgressView() throws {
        let idle = try savedModel(); idle.bugReportIssueIsFiling = false
        XCTAssertThrowsError(try ReportBugSheet(model: idle).inspect().find(ViewType.ProgressView.self),
                             "idle: no in-flight spinner")
        let filing = try savedModel(); filing.bugReportIssueIsFiling = true
        XCTAssertNoThrow(try ReportBugSheet(model: filing).inspect().find(ViewType.ProgressView.self),
                         "filing: the spinner renders")
    }

    // MARK: - Footer button (`:2567`) — "Create Report" (`:2579`) is the live-AppKit carve

    /// "Open Reports Folder" `Button { model.revealBugReportsFolder() }` (`:2567`).
    /// Creates + opens the (hermetic temp) bug-reports folder.
    func testReportBug_openReportsFolderButton_tapRunsReveal() throws {
        let model = try makeVM()
        try ReportBugSheet(model: model).inspect().find(button: "Open Reports Folder").tap()
        XCTAssertNil(model.errorMessage, "revealing the hermetic temp folder does not error")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The Copy-Path / file-issue actions each produce an observable side-effect (pasteboard
    /// path / filing flag). A no-op action would leave them unchanged — the mutation that
    /// breaks each guard.
    func testReportBug_negativeControl_actionsProduceEffects() throws {
        let copyModel = try savedModel()
        NSPasteboard.general.clearContents()
        try ReportBugSheet(model: copyModel).inspect().find(button: "Copy Path").tap()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), Self.fixedBundleURL.path)

        let fileModel = try savedModel()
        try ReportBugSheet(model: fileModel).inspect().find(button: "File as GitHub Issue").tap()
        XCTAssertTrue(fileModel.bugReportIssueIsFiling)
    }

    // MARK: - Determinism (P3)

    func testReportBug_interaction_noLeak() throws {
        let model = try savedModel()
        let tree = try ViewSnapshotHost.snapshotText(of: ReportBugSheet(model: model))
        XCTAssertFalse(tree.contains("/Users/"), "no machine-path leak:\n\(tree)")
        XCTAssertFalse(tree.contains("/var/folders/"), "no temp-path leak:\n\(tree)")
    }
}
#endif
