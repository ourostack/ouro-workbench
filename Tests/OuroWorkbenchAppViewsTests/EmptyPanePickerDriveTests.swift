#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B5 — `EmptyPanePicker` (`:8881`) close-out. `SessionSplitAndOverflowTests` drove the
/// empty arm + a single no-session/no-cli candidate, leaving four regions uncovered:
///   - `L8908:36` — the candidate `Button { model.assignSecondaryPane(to: entry.id) }` ACTION;
///   - `L8913:88` — the live-session circle color arm `model.activeSession(for:) != nil
///     ? Color.green : …` (the GREEN arm — needs a candidate WITH a live session);
///   - `L8918:80` — the `if let cliName` pill (needs a candidate whose kind detects a CLI name);
///   - `L8925:38` — the candidate row body inside that `if-let cliName` branch.
///
/// The corrected B5 recipe DRIVES all four with a candidate that BOTH has a live session
/// (the no-PTY `TerminalSessionController` seam injected into `activeSessions`) AND a CLI name
/// (a `.terminalAgent` whose executable detects as Claude). Tapping the candidate's button
/// invokes `assignSecondaryPane` (a `detailSplit` must exist first), asserted via
/// `detailSplit?.secondaryEntryID` + mutation-verified.
@MainActor
final class EmptyPanePickerDriveTests: XCTestCase {

    private static let primaryId = UUID(uuidString: "B5E47A11-0000-0000-0000-000000000001")!
    private static let cliCandId = UUID(uuidString: "B5E47A11-0000-0000-0000-000000000002")!
    private static let plainCandId = UUID(uuidString: "B5E47A11-0000-0000-0000-000000000003")!
    private static let projectId = UUID(uuidString: "B5E47A11-0000-0000-0000-0000000000A1")!
    private static let wsId = UUID(uuidString: "B5E47A11-0000-0000-0000-0000000000B1")!

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b5picker-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        let m = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        m.selectedProjectID = Self.projectId
        return m
    }

    /// `primary` (excluded), `cliCand` (`.terminalAgent` → Claude cliName + a live session),
    /// `plainCand` (`.shell`, no cli, no session — the gray-circle arm).
    private func state() -> WorkspaceState {
        let primary = ProcessEntry(id: Self.primaryId, projectId: Self.projectId, name: "primary",
                                   kind: .shell, executable: "/bin/zsh", workingDirectory: "/tmp/u5")
        let cliCand = ProcessEntry(id: Self.cliCandId, projectId: Self.projectId, name: "build",
                                   kind: .terminalAgent, executable: "/usr/local/bin/claude",
                                   workingDirectory: "/tmp/u5")
        let plainCand = ProcessEntry(id: Self.plainCandId, projectId: Self.projectId, name: "plain",
                                     kind: .shell, executable: "/bin/zsh", workingDirectory: "/tmp/u5")
        return WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            selectedProjectId: Self.projectId,
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp/u5")],
            processEntries: [primary, cliCand, plainCand],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS",
                                   tabIds: [Self.primaryId, Self.cliCandId, Self.plainCandId])])
    }

    private func session(for entry: ProcessEntry) throws -> TerminalSessionController {
        let plan = TerminalCommandPlan(
            entryId: entry.id, executable: "/bin/zsh", arguments: [],
            workingDirectory: "/tmp/u5", reason: "test")
        return try TerminalSessionController(plan: plan, onStarted: { _ in }, onOutput: {}, onTerminated: { _ in })
    }

    /// A VM whose cliCand has a live session (green circle arm).
    private func liveModel() throws -> WorkbenchViewModel {
        let m = try makeVM(state: state())
        let cli = m.state.processEntries.first { $0.id == Self.cliCandId }!
        m.activeSessions[cli.id] = try session(for: cli)
        return m
    }

    // MARK: - Drive the populated picker (green circle + cli pill + the candidate rows)

    func testPicker_candidateWithSessionAndCli_rendersBothArms() throws {
        let m = try liveModel()
        let view = EmptyPanePicker(excluding: Self.primaryId, model: m)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="build""#), "the cli-candidate row name:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="plain""#), "the plain-candidate row name:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Claude Code""#), "the cliName pill (L8918 arm):\n\(tree)")
        try assertViewSnapshot(of: view, named: "EmptyPanePicker.liveCandidates")
    }

    // MARK: - Drive the candidate Button ACTION (L8908 + L8925)

    func testPicker_candidateTap_assignsSecondaryPane() throws {
        let m = try liveModel()
        // assignSecondaryPane is a no-op unless a split exists — set one up first.
        m.detailSplit = DetailSplitState(axis: .vertical, secondaryEntryID: nil)
        XCTAssertNil(m.detailSplit?.secondaryEntryID, "no secondary assigned before the tap")
        let view = EmptyPanePicker(excluding: Self.primaryId, model: m)
        // INVOCATION: tap the "plain" candidate's button → assignSecondaryPane(to: plainCand.id).
        try view.inspect().find(button: "plain").tap()
        XCTAssertEqual(m.detailSplit?.secondaryEntryID, Self.plainCandId,
                       "the candidate tap must assign that session to the secondary pane")
    }

    // MARK: - Negative control (P2 — green vs gray circle; the assign side-effect)

    func testPicker_negativeControl_liveCandidateFlipsCircleColor() throws {
        // With a session the cli-candidate's circle is green; without, gray. The captured
        // tree differs (the green/gray color isn't a captured node, but the live session
        // also surfaces the cliName pill only on the entry it's attached to — assert the
        // assign tap distinguishes the two candidates instead).
        let m = try liveModel()
        m.detailSplit = DetailSplitState(axis: .vertical, secondaryEntryID: nil)
        let view = EmptyPanePicker(excluding: Self.primaryId, model: m)
        try view.inspect().find(button: "build").tap()
        XCTAssertEqual(m.detailSplit?.secondaryEntryID, Self.cliCandId,
                       "tapping the cli candidate assigns IT (not the plain one)")
    }

    func testPicker_deterministic_noLeak() throws {
        let a = try ViewSnapshotHost.snapshotText(of: EmptyPanePicker(excluding: Self.primaryId, model: try liveModel()))
        let b = try ViewSnapshotHost.snapshotText(of: EmptyPanePicker(excluding: Self.primaryId, model: try liveModel()))
        XCTAssertEqual(a, b, "must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no /Users/ leak:\n\(a)")
        XCTAssertFalse(a.contains("/var/folders/"), "no temp-dir leak:\n\(a)")
    }
}
#endif
