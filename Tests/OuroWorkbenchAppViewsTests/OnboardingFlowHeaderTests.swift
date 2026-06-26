#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C6-3 — `OnboardingFlowHeader` (`:6644`, widened `private`→`internal` for `@testable import`).
///
/// The wizard header has two data-driven captured-node flips:
///   - `page.title` + `page.systemImage` (`:6621/6616`) — the page heading + the SF-symbol glyph,
///     driven by the injected `OnboardingPage` (`.boss` → "Choose Boss" / person-glyph; `.connect`
///     → "Connect" / link-glyph; `.importWork` → "Bring Back Work" / uturn-glyph).
///   - `model.onboardingHasBeenCompleted ? "Done" : "Cancel"` (`:6632`) — the honest dismiss label:
///     "Cancel" until onboarding is genuinely completed (a mid-wizard pick still rolls back), "Done"
///     once committed.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` store seam (AN-001 dual-injection); the
/// `OnboardingPage` is the REAL (now-`internal`) wizard-page enum; `onboardingHasBeenCompleted` is
/// the SAME `@Published` the production `advance()` sets. `dismiss` is a real `DismissAction` taken
/// from a host environment read (the standalone-leaf pattern). NO fabricated state.
///
/// **Determinism (P3).** No clock / path / machine value — page title/image are static enum copy.
/// Byte-identical twice; no `/Users/` leak.
///
/// **Non-vacuity (P2).** Each page flips the captured `Text(page.title)` + the `Image` glyph; the
/// `hasBeenCompleted` flag flips the captured "Done"/"Cancel" button label. The negative controls
/// assert the flips.
@MainActor
final class OnboardingFlowHeaderTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c6-onbhdr-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(
            WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    /// Wrap the header so a real `DismissAction` is read from the host environment — the header
    /// takes `dismiss: DismissAction`, which is only constructible via `@Environment(\.dismiss)`.
    private struct HeaderHost: View {
        let page: WorkbenchOnboardingSheet.OnboardingPage
        @ObservedObject var model: WorkbenchViewModel
        @Environment(\.dismiss) private var dismiss
        var body: some View {
            OnboardingFlowHeader(page: page, model: model, dismiss: dismiss)
        }
    }

    private func header(page: WorkbenchOnboardingSheet.OnboardingPage,
                        completed: Bool = false) throws -> HeaderHost {
        let model = try makeVM()
        model.onboardingHasBeenCompleted = completed
        return HeaderHost(page: page, model: model)
    }

    // MARK: - Enumerated state-set

    func testHeader_bossPage_cancel() throws {
        try assertViewSnapshot(of: try header(page: .boss, completed: false),
                               named: "OnboardingFlowHeader.bossPage")
    }

    func testHeader_connectPage() throws {
        try assertViewSnapshot(of: try header(page: .connect, completed: false),
                               named: "OnboardingFlowHeader.connectPage")
    }

    func testHeader_importWorkPage_done() throws {
        try assertViewSnapshot(of: try header(page: .importWork, completed: true),
                               named: "OnboardingFlowHeader.importWorkPageDone")
    }

    // MARK: - Determinism (P3)

    func testHeader_determinism_byteIdenticalTwiceNoLeak() throws {
        let cases: [(String, WorkbenchOnboardingSheet.OnboardingPage, Bool)] = [
            ("bossPage", .boss, false),
            ("connectPage", .connect, false),
            ("importWorkPageDone", .importWork, true),
        ]
        for (name, page, completed) in cases {
            let a = try ViewSnapshotHost.snapshotText(of: try header(page: page, completed: completed))
            let b = try ViewSnapshotHost.snapshotText(of: try header(page: page, completed: completed))
            XCTAssertEqual(a, b, "\(name) must be byte-identical twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }

    // MARK: - Negative controls (P2 — mutation-verified)

    /// The `page.title` flips the captured heading per page.
    func testHeader_negativeControl_pageFlipsTitle() throws {
        let boss = try ViewSnapshotHost.snapshotText(of: try header(page: .boss))
        let connect = try ViewSnapshotHost.snapshotText(of: try header(page: .connect))
        let importWork = try ViewSnapshotHost.snapshotText(of: try header(page: .importWork))

        XCTAssertTrue(boss.contains("Choose Boss"), "boss: the page title renders:\n\(boss)")
        XCTAssertTrue(connect.contains("Connect"), "connect: the page title renders")
        XCTAssertTrue(importWork.contains("Bring Back Work"), "importWork: the page title renders")
        XCTAssertNotEqual(boss, connect)
        XCTAssertNotEqual(connect, importWork)
    }

    /// The `onboardingHasBeenCompleted` ternary flips the captured dismiss-button label.
    func testHeader_negativeControl_completedFlipsButton() throws {
        let cancel = try ViewSnapshotHost.snapshotText(of: try header(page: .boss, completed: false))
        let done = try ViewSnapshotHost.snapshotText(of: try header(page: .boss, completed: true))

        XCTAssertNotEqual(cancel, done, "the hasBeenCompleted ternary must drive the button")
        XCTAssertTrue(cancel.contains("Cancel"), "not-completed: the button reads Cancel:\n\(cancel)")
        XCTAssertFalse(cancel.contains("Done"), "not-completed: not Done")
        XCTAssertTrue(done.contains("Done"), "completed: the button reads Done:\n\(done)")
        XCTAssertFalse(done.contains("Cancel"), "completed: not Cancel")
    }
}
#endif
