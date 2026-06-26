#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C3-8 — `HeaderView` (`:4002`) enumerated state-set (the deterministic no-boss composite).
///
/// `HeaderView`'s OWN logic-bearing branches are `if statusLine.shouldShow` (`:4015`, a direct
/// `Text(statusLine.text)`), `if let badge = model.updateBadgeText` (`:4024`, the update button),
/// the collapsed-pane overlay `if model.state.bossPaneCollapsed, let door = model.inboxDoor`
/// (`:4061`, the count badge), and `ForEach(model.recentWorkspacePaths)` (`:4109`, inside the
/// More `Menu`). The header also embeds `BossSelectorView` / `AutonomyStatusButton` /
/// `BossWatchHeaderToggle`.
///
/// **Login-item determinism (P3 — the no-boss carve).** The embedded `AutonomyStatusButton`'s
/// label folds the NON-INJECTABLE login-item state into `ttfaText` ONLY when a boss is set (the
/// `MachineRuntimeView`-class taint — see `AutonomyStatusButtonTests` + allowlist candidate #6).
/// With an EMPTY boss name the embedded button is on its login-INDEPENDENT neutral arm
/// ("TTFA · off"), `BossWatchHeaderToggle` is hidden (no usable boss), and `BossSelectorView`
/// reads "No boss yet" — so the WHOLE header is deterministic. Every fixture here uses an empty
/// boss; the determinism guard (two fresh login controllers → byte-identical) proves it. The
/// boss-set header (login-tainted via the embedded button) is the recorded carve, NOT fabricated.
///
/// The collapsed-pane `inboxDoor` badge is also DEFERRED here: `InboxDoorPresentation.resolve`
/// reads `state.openInbox(now: Date())` (a clock-dependent default) — so the inbox-door arm is a
/// clock seam covered at its own cluster (C4 decision inbox), not forced into this header fixture.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` store seam (AN-001). `statusLine` is
/// driven through the REAL `HeaderStatusLinePresentation.resolve(summary:)` seam: a persisted
/// `.waitingOnHuman` entry makes `summary.waitingOnHuman` non-empty → `shouldShow == true`; a
/// quiet machine hides it. `recentWorkspacePaths` defaults to `[]` (the empty-recent menu arm).
///
/// **Enumerated state-set (HeaderView's own statusLine branch):**
///   - `calmQuiet`       — empty boss, no entries → `statusLine.shouldShow == false` (the calm
///                          first-run header) — the statusLine `Text` is absent.
///   - `statusLineShown` — empty boss + a `.waitingOnHuman` entry → `shouldShow == true` → the
///                          status `Text("… waiting on human input")` renders.
@MainActor
final class HeaderViewTests: XCTestCase {

    private func makeVM(_ state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c3-hdr-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!
    private static let tabId = UUID(uuidString: "11111111-0000-0000-0000-0000000000AB")!
    private static let wsId = UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000AB")!

    /// A quiet, boss-less state → the calm first-run header (statusLine hidden).
    private func quietState() -> WorkspaceState {
        WorkspaceState(boss: BossAgentSelection(agentName: ""))
    }

    /// A boss-less state with a `.waitingOnHuman` entry → `statusLine.shouldShow == true`.
    private func waitingState() -> WorkspaceState {
        let entry = ProcessEntry(
            id: Self.tabId, projectId: Self.projectId, name: "wait-tab",
            kind: .shell, executable: "/bin/zsh", workingDirectory: "/tmp/c3hdr",
            attention: .waitingOnHuman
        )
        return WorkspaceState(
            boss: BossAgentSelection(agentName: ""),
            processEntries: [entry],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: [Self.tabId])]
        )
    }

    private func header(_ state: WorkspaceState) throws -> HeaderView {
        HeaderView(model: try makeVM(state))
    }

    // MARK: - Enumerated state-set

    func testHeader_calmQuiet() throws {
        let view = try header(quietState())
        XCTAssertFalse(view.model.headerStatusLine.shouldShow,
                       "provenance: a quiet machine hides the status line")
        try assertViewSnapshot(of: view, named: "HeaderView.calmQuiet")
    }

    func testHeader_statusLineShown() throws {
        let view = try header(waitingState())
        XCTAssertTrue(view.model.headerStatusLine.shouldShow,
                      "provenance: a waiting entry shows the status line")
        XCTAssertTrue(view.model.headerStatusLine.text.contains("waiting on human"),
                      "provenance: the waiting status text")
        try assertViewSnapshot(of: view, named: "HeaderView.statusLineShown")
    }

    // MARK: - Determinism (P3) — login-item independence of the no-boss header

    /// The no-boss header is login-item-INDEPENDENT (the embedded button is on its neutral arm):
    /// two FRESH (live-state) controllers render byte-identical trees, no machine path leaks.
    func testHeader_determinism_loginItemIndependentAndNoLeak() throws {
        for (name, state) in [("calmQuiet", quietState()), ("statusLineShown", waitingState())] {
            let a = try ViewSnapshotHost.snapshotText(of: try header(state))
            let b = try ViewSnapshotHost.snapshotText(of: try header(state))
            XCTAssertEqual(a, b, "\(name) must be byte-identical across fresh login controllers")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The `if statusLine.shouldShow` gate renders-vs-hides the status `Text`, and the waiting
    /// entry's name reaches the rendered status text (a real value through the summary seam).
    func testHeader_negativeControl_statusLineGateFlipsTree() throws {
        let calm = try ViewSnapshotHost.snapshotText(of: try header(quietState()))
        let shown = try ViewSnapshotHost.snapshotText(of: try header(waitingState()))

        XCTAssertNotEqual(calm, shown, "the statusLine.shouldShow gate must drive the tree")
        XCTAssertFalse(calm.contains("waiting on human"), "calm: no status line:\n\(calm)")
        XCTAssertTrue(shown.contains("waiting on human"), "shown: the status line renders:\n\(shown)")
    }
}
#endif
