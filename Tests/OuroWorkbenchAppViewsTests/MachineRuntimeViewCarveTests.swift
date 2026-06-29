#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C10-7 — `MachineRuntimeView` (`:10292`), the **non-injectable login-item carve**
/// (allowlist-candidate #2). The view's `body` mixes TWO regions:
///
///   1. The **login-item rows** (`Toggle "Open at Login"` + `DashboardStatusLine(loginItem.statusLine)`
///      + the optional `loginItem.lastError` + `Refresh`) read a `@StateObject LoginItemController()`
///      constructed IN-PLACE (`:10294`, no `paths`/init seam). `LoginItemController.status` is set in
///      `init()` from the live `LaunchAgentLoginItem(appURL:.defaultAppURL()).status()` — whether
///      `~/Applications/Ouro Workbench.app` + the LaunchAgents plist exist on THIS machine. So the
///      `statusLine` is MACHINE-DEPENDENT (`.enabled`→"enabled" on a dev machine WITH the app;
///      `.appBundleMissing`→"install app first" on a clean CI runner) and CANNOT be committed as a
///      cross-runner-deterministic reference. There is NO injection seam (`init()` takes no params).
///      → **ALLOWLIST-carve those rows** (recorded below; a future `LoginItemController`
///      protocol-injection seam would reclaim them — a POSSIBLE source-fix, NOT done in U4).
///
///   2. The **Support Diagnostics rows** are MODEL-driven (`model.supportDiagnostics*`, all
///      `@Published` / pure accessors) → fully deterministic → **COVERED** here.
///
/// **The carve mechanism (the C3 `strippingLoginFooter` precedent).** The committed reference is
/// the **login-stripped projection**: `supportDiagnosticsSubtree(_:)` drops every node BEFORE the
/// "Support Diagnostics" label (the entire login-item region), so the reference carries only the
/// deterministic Support-Diagnostics subtree. `testCarve_loginRegionIsTheOnlyNonDeterministicPart`
/// PROVES the carve is complete + sound: the stripped subtree is byte-identical across TWO FRESH
/// (live-state) `MachineRuntimeView`s — i.e. the login-item `@StateObject` taint is entirely
/// confined to the stripped region.
///
/// **Provenance (P2).** `supportDiagnosticsResult` is a real `SupportDiagnosticsResult` (the same
/// type the runner emits) with a FIXED, relative `archiveURL` whose `lastPathComponent` is the only
/// visible path token; `supportDiagnosticsError` / `supportDiagnosticsIsCollecting` are the real
/// `@Published`s the async collector sets. The `supportDiagnosticsURL?.path` is rendered ONLY into
/// the dropped `.help()` tooltip. NO fabricated state.
///
/// **No clock surface** in either region → no cross-TZ proof needed.
@MainActor
final class MachineRuntimeViewCarveTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c10machine-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    /// A FIXED, relative diagnostics archive (only its `lastPathComponent` is rendered visibly).
    private func result() -> SupportDiagnosticsResult {
        SupportDiagnosticsResult(
            archiveURL: URL(fileURLWithPath: "/tmp/u4/diagnostics/ouro-support.zip"), output: "")
    }

    private enum Diagnostics { case notRun, collected, failed, collecting }

    private func view(_ diagnostics: Diagnostics) throws -> MachineRuntimeView {
        let model = try makeVM()
        switch diagnostics {
        case .notRun:
            break
        case .collected:
            model.supportDiagnosticsResult = result()
        case .failed:
            model.supportDiagnosticsError = "could not write archive"
        case .collecting:
            model.supportDiagnosticsIsCollecting = true
        }
        return MachineRuntimeView(model: model)
    }

    /// The login-item carve: keep ONLY the Support-Diagnostics subtree (from the "Support
    /// Diagnostics" label onward), dropping the entire machine-local login-item region. The
    /// stripped projection is what gets committed + diffed — cross-runner deterministic.
    private func supportDiagnosticsSubtree(_ diagnostics: Diagnostics) throws -> String {
        let raw = try ViewSnapshotHost.snapshotText(of: try view(diagnostics))
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains(#"text="Support Diagnostics""#) }) else {
            return raw   // defensive: if the anchor moves, fail loudly on the full (login-tainted) tree
        }
        return lines[start...].joined(separator: "\n")
    }

    private let store = ViewSnapshotStore.default(testFilePath: #filePath)

    // MARK: - Enumerated state-set (the COVERED Support-Diagnostics region; login rows carved)

    /// NOT RUN — "not run" status, no Reveal/Copy-Path buttons (`supportDiagnosticsURL == nil`).
    func testCarve_notRun() throws {
        XCTAssertEqual(try view(.notRun).model.supportDiagnosticsStatusLine, "not run",
                       "provenance: no result → 'not run'")
        XCTAssertNil(try view(.notRun).model.supportDiagnosticsURL, "provenance: no archive → no Reveal/Copy")
        try assertViewSnapshotText(try supportDiagnosticsSubtree(.notRun),
                                   named: "MachineRuntimeView.diagnosticsNotRun", store: store)
    }

    /// COLLECTED — "wrote <archive>" + the Reveal + Copy-Path buttons (`supportDiagnosticsURL != nil`).
    func testCarve_collected() throws {
        XCTAssertEqual(try view(.collected).model.supportDiagnosticsStatusLine, "wrote ouro-support.zip",
                       "provenance: a result → 'wrote <lastPathComponent>'")
        XCTAssertNotNil(try view(.collected).model.supportDiagnosticsURL, "provenance: an archive → Reveal/Copy")
        try assertViewSnapshotText(try supportDiagnosticsSubtree(.collected),
                                   named: "MachineRuntimeView.diagnosticsCollected", store: store)
    }

    /// FAILED — "failed: <error>" status (the error branch), no Reveal/Copy.
    func testCarve_failed() throws {
        XCTAssertEqual(try view(.failed).model.supportDiagnosticsStatusLine, "failed: could not write archive",
                       "provenance: an error → 'failed: <error>'")
        try assertViewSnapshotText(try supportDiagnosticsSubtree(.failed),
                                   named: "MachineRuntimeView.diagnosticsFailed", store: store)
    }

    /// COLLECTING — "collecting" status + the in-flight spinner; the Collect button is disabled
    /// (the `.disabled` modifier is host-dropped, but the "collecting" line + the absence of
    /// Reveal/Copy mark the state).
    func testCarve_collecting() throws {
        XCTAssertEqual(try view(.collecting).model.supportDiagnosticsStatusLine, "collecting",
                       "provenance: isCollecting → 'collecting'")
        try assertViewSnapshotText(try supportDiagnosticsSubtree(.collecting),
                                   named: "MachineRuntimeView.diagnosticsCollecting", store: store)
    }

    // MARK: - The carve is sound + complete (P3)

    /// The login-item region is the ONLY non-deterministic part: with it stripped, the
    /// Support-Diagnostics subtree is byte-identical across TWO FRESH `MachineRuntimeView`s (each
    /// builds a fresh live-state `LoginItemController`), and carries no machine path. This PROVES
    /// the committed (stripped) reference is cross-machine deterministic and the carve is complete.
    func testCarve_loginRegionIsTheOnlyNonDeterministicPart() throws {
        for diagnostics in [Diagnostics.notRun, .collected, .failed, .collecting] {
            let a = try supportDiagnosticsSubtree(diagnostics)
            let b = try supportDiagnosticsSubtree(diagnostics)
            XCTAssertEqual(a, b, "the stripped Support-Diagnostics subtree must be byte-identical across fresh controllers")
            XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
            XCTAssertFalse(a.contains("/var/folders/"), "no temp-dir path leak:\n\(a)")
            // The carve dropped the login region — none of its status words may remain.
            for loginWord in ["Open at Login", "enabled", "not registered", "install app first", "update needed"] {
                XCTAssertFalse(a.contains(loginWord), "carve: the login-item region is stripped (\(loginWord)):\n\(a)")
            }
        }
    }

    // MARK: - Negative control (P2 — mutation-verified, the COVERED region)

    /// The diagnostics state flips the covered subtree: "not run" → "wrote …" adds the Reveal +
    /// Copy-Path buttons; an error reads "failed: …" — real `model.supportDiagnostics*`-driven
    /// branches.
    func testCarve_negativeControl_diagnosticsStateFlipsSubtree() throws {
        let notRun = try supportDiagnosticsSubtree(.notRun)
        let collected = try supportDiagnosticsSubtree(.collected)
        let failed = try supportDiagnosticsSubtree(.failed)

        XCTAssertNotEqual(notRun, collected, "a result must flip the diagnostics subtree")
        XCTAssertTrue(notRun.contains("not run"), "not-run: the status line:\n\(notRun)")
        XCTAssertFalse(notRun.contains("Reveal"), "not-run: no Reveal button (no archive)")
        XCTAssertTrue(collected.contains("wrote ouro-support.zip"), "collected: the wrote line:\n\(collected)")
        XCTAssertTrue(collected.contains("Reveal"), "collected: the Reveal button renders")
        XCTAssertTrue(collected.contains("Copy Path"), "collected: the Copy-Path button renders")

        XCTAssertNotEqual(collected, failed, "an error must flip the subtree")
        XCTAssertTrue(failed.contains("failed: could not write archive"), "failed: the error status:\n\(failed)")
        XCTAssertFalse(failed.contains("Reveal"), "failed: no Reveal button")
    }

    // MARK: - Action closures (the deterministic support-diagnostics buttons)

    /// The Support Diagnostics "Collect" button executes `model.collectSupportDiagnostics()`.
    /// Use the existing no-child seam so the tap only proves the view action path and does not
    /// spawn the collector in-process.
    func testCarve_collectButton_tapStartsCollection() throws {
        let view = try view(.notRun)
        view.model.runSupportDiagnostics = { _ in
            throw SupportDiagnosticsRunnerError.scriptMissing(["test no-op"])
        }

        XCTAssertFalse(view.model.supportDiagnosticsIsCollecting, "precondition")
        try view.inspect().find(button: "Collect").tap()

        XCTAssertTrue(view.model.supportDiagnosticsIsCollecting,
                      "tapping Collect routes through MachineRuntimeView to collectSupportDiagnostics")
    }

    /// The "Reveal" button is only present when an archive exists; tapping it records the model
    /// action after calling the injected Finder reveal seam.
    func testCarve_revealButton_tapRunsAction() throws {
        let view = try view(.collected)
        var revealedURLs: [URL] = []
        view.model.revealFileViewerSelectingURLs = { revealedURLs = $0 }
        let before = view.model.state.actionLog.count

        try view.inspect().find(button: "Reveal").tap()

        XCTAssertEqual(view.model.state.actionLog.count, before + 1)
        XCTAssertEqual(view.model.state.actionLog.first?.action, "revealSupportDiagnostics")
        XCTAssertEqual(revealedURLs, [result().archiveURL])
    }

    /// The "Copy Path" button is also archive-gated; tapping it copies through the model seam and
    /// logs the action.
    func testCarve_copyPathButton_tapRunsAction() throws {
        let view = try view(.collected)
        let before = view.model.state.actionLog.count

        try view.inspect().find(button: "Copy Path").tap()

        XCTAssertEqual(view.model.state.actionLog.count, before + 1)
        XCTAssertEqual(view.model.state.actionLog.first?.action, "copySupportDiagnosticsPath")
    }
}
#endif
