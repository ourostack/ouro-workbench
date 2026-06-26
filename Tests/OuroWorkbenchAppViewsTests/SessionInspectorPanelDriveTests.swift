#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B5 — `SessionInspectorPanel` (`:9192`) close-out. `SessionInspectorAndTitleStripTests`
/// drove the basic / notes / transcript-button RENDER arms but left these uncovered:
///   - `L9203:60` — the `if let cliName` purple pill (needs a CLI-named entry);
///   - `L9205:18 / L9206:57 / L9208:18` — the `if let badge = entry.owner.sidebarBadge` teal
///     pill (needs an `.agent`-owned entry);
///   - `L9214:46 / L9214:62 / L9215:47 / L9215:55` — BOTH arms of the auto-resume status-pill
///     ternary (`entry.autoResume ? "auto-resume"/.blue : "manual restart"/.secondary`);
///   - `L9242:28` — the `Button { onShowTranscript() }` Transcript ACTION (the existing test
///     renders the button but never taps it).
///
/// DRIVEN via real seams: a `.terminalAgent` (cliName) `.agent`-owned (badge) entry with a real
/// transcript file (Transcript button) covers cliName + badge + the auto-resume arm; a second
/// `manual-restart` entry covers the other ternary arm; the Transcript button is INVOKED via
/// `.tap()` (asserts `onShowTranscript` ran). FIXED `/tmp/u5` paths, leak-defended.
@MainActor
final class SessionInspectorPanelDriveTests: XCTestCase {

    private static let entryId = UUID(uuidString: "B5121593-0000-0000-0000-0000000000E1")!
    private static let projectId = UUID(uuidString: "B5121593-0000-0000-0000-0000000000A1")!
    private static let wsId = UUID(uuidString: "B5121593-0000-0000-0000-0000000000B1")!
    private static let runEpoch = Date(timeIntervalSince1970: 1_700_000_000)
    private static let transcriptPath = "/tmp/u5-inspector/history.log"

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b5inspector-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    private func entry(
        kind: ProcessKind = .terminalAgent,
        executable: String = "/usr/local/bin/claude",
        autoResume: Bool = true,
        owner: SessionOwner = .agent(name: "boss-agent")
    ) -> ProcessEntry {
        ProcessEntry(
            id: Self.entryId, projectId: Self.projectId, name: "build",
            kind: kind, executable: executable, workingDirectory: "/tmp/u5",
            trust: .trusted, autoResume: autoResume, owner: owner)
    }

    private func run(_ status: ProcessStatus, transcriptPath: String? = nil) -> ProcessRun {
        ProcessRun(id: UUID(uuidString: "B5121593-0000-0000-0000-0000000000F1")!,
                   entryId: Self.entryId, status: status, startedAt: Self.runEpoch,
                   transcriptPath: transcriptPath)
    }

    private func state(entry: ProcessEntry, runs: [ProcessRun] = []) -> WorkspaceState {
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp/u5")],
            processEntries: [entry],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: [Self.entryId])],
            processRuns: runs)
    }

    private func loaded(_ m: WorkbenchViewModel, fallback: ProcessEntry) -> ProcessEntry {
        m.state.processEntries.first ?? fallback
    }

    private func writeTranscript() throws {
        let file = URL(fileURLWithPath: Self.transcriptPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "agent: done\n".data(using: .utf8)!.write(to: file)
    }

    // MARK: - cliName + badge + auto-resume arm + Transcript button (one rich fixture)

    func testInspector_richEntry_rendersCliBadgeAutoResumeAndTranscript() throws {
        try writeTranscript()
        let e = entry()
        let m = try makeVM(state: state(entry: e, runs: [run(.exited, transcriptPath: Self.transcriptPath)]))
        let le = loaded(m, fallback: e)
        XCTAssertNotNil(m.cliName(for: le), "provenance: terminalAgent → a cliName pill")
        XCTAssertNotNil(le.owner.sidebarBadge, "provenance: agent-owned → the badge pill")
        XCTAssertNotNil(m.transcriptTail(for: le), "provenance: real transcript → the Transcript button")
        let view = SessionInspectorPanel(entry: le, model: m, onShowTranscript: {})
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="Claude Code""#), "the cliName pill (L9203):\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="boss-agent""#), "the owner badge pill (L9205-9208):\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="auto-resume""#), "the auto-resume arm (L9214/9215):\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Transcript""#), "the Transcript button:\n\(tree)")
        try assertViewSnapshot(of: view, named: "SessionInspectorPanel.rich")
    }

    // MARK: - The manual-restart ternary arm

    func testInspector_manualRestart_rendersManualArm() throws {
        let e = entry(autoResume: false)
        let m = try makeVM(state: state(entry: e))
        let le = loaded(m, fallback: e)
        let view = SessionInspectorPanel(entry: le, model: m, onShowTranscript: {})
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="manual restart""#), "the manual-restart arm:\n\(tree)")
        XCTAssertFalse(tree.contains(#"text="auto-resume""#), "manual: not auto-resume:\n\(tree)")
        try assertViewSnapshot(of: view, named: "SessionInspectorPanel.manualRestart")
    }

    // MARK: - L9242 — drive the Transcript button ACTION

    func testInspector_transcriptTap_invokesCallback() throws {
        try writeTranscript()
        var shown = false
        let e = entry()
        let m = try makeVM(state: state(entry: e, runs: [run(.exited, transcriptPath: Self.transcriptPath)]))
        let le = loaded(m, fallback: e)
        let view = SessionInspectorPanel(entry: le, model: m, onShowTranscript: { shown = true })
        // INVOCATION: tap the Transcript button → runs onShowTranscript().
        try view.inspect().find(button: "Transcript").tap()
        XCTAssertTrue(shown, "the Transcript tap must invoke onShowTranscript")
    }

    // MARK: - Negative control (P2 mutation-verified)

    func testInspector_negativeControl_autoResumeFlipsPill() throws {
        let auto = try ViewSnapshotHost.snapshotText(of: { () -> SessionInspectorPanel in
            let e = entry(autoResume: true); let m = try makeVM(state: state(entry: e))
            return SessionInspectorPanel(entry: loaded(m, fallback: e), model: m, onShowTranscript: {})
        }())
        let manual = try ViewSnapshotHost.snapshotText(of: { () -> SessionInspectorPanel in
            let e = entry(autoResume: false); let m = try makeVM(state: state(entry: e))
            return SessionInspectorPanel(entry: loaded(m, fallback: e), model: m, onShowTranscript: {})
        }())
        XCTAssertNotEqual(auto, manual, "the auto-resume ternary must flip the pill")
        XCTAssertTrue(auto.contains(#"text="auto-resume""#))
        XCTAssertTrue(manual.contains(#"text="manual restart""#))
    }

    func testInspector_deterministic_noLeak() throws {
        func make() throws -> String {
            try writeTranscript()
            let e = entry()
            let m = try makeVM(state: state(entry: e, runs: [run(.exited, transcriptPath: Self.transcriptPath)]))
            return try ViewSnapshotHost.snapshotText(of:
                SessionInspectorPanel(entry: loaded(m, fallback: e), model: m, onShowTranscript: {}))
        }
        let a = try make(); let b = try make()
        XCTAssertEqual(a, b, "must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no /Users/ leak:\n\(a)")
        XCTAssertFalse(a.contains("/var/folders/"), "no temp-dir leak:\n\(a)")
    }
}
#endif
