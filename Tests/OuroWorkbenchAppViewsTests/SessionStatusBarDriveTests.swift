#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B5 — `SessionStatusBar` (`:9308`) close-out. C9 drove the archived /
/// recoverable / configured RENDER arms (labels), but carved three regions:
///   - `L9321:28` — the archived `Restore` button's ACTION `{ model.restoreCustomSession(entry) }`;
///   - `L9328:28` — the `Recover` button's ACTION `{ model.recover(entry) }`;
///   - `L9346:98` — the `.orange` arm of the executable-health color ternary
///     `health.status == .available ? .secondary : .orange` (needs a non-available health).
///
/// The corrected B5 recipe DRIVES all three:
///   - Restore tap → `restoreCustomSession` synchronously replaces the entry with its
///     restored (non-archived) form in `model.state.processEntries` — asserted + mutation-verified.
///   - Recover tap → on an EMPTY-executable but recoverable entry, `recover(_:)` routes through
///     `WorkbenchCommandPlanner().recoveryPlan(...)` which throws `emptyExecutable`, so the catch
///     arm sets `model.errorMessage` SYNCHRONOUSLY (no `Task`/no process spawn) — asserted.
///   - the `.orange` health arm → inject a `.missing` `ExecutableHealth` so the non-available
///     branch renders the orange color + the "Executable: …" row.
@MainActor
final class SessionStatusBarDriveTests: XCTestCase {

    private static let entryId = UUID(uuidString: "B5577A78-0000-0000-0000-0000000000E1")!
    private static let projectId = UUID(uuidString: "B5577A78-0000-0000-0000-0000000000A1")!
    private static let wsId = UUID(uuidString: "B5577A78-0000-0000-0000-0000000000B1")!
    private static let runEpoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b5statusbar-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    private func entry(
        isArchived: Bool = false, executable: String = "/bin/zsh", autoResume: Bool = false
    ) -> ProcessEntry {
        ProcessEntry(
            id: Self.entryId, projectId: Self.projectId, name: "build",
            kind: .shell, executable: executable, workingDirectory: "/tmp/u5",
            trust: .trusted, autoResume: autoResume, isArchived: isArchived)
    }

    private func run(_ status: ProcessStatus) -> ProcessRun {
        ProcessRun(id: UUID(uuidString: "B5577A78-0000-0000-0000-0000000000F1")!,
                   entryId: Self.entryId, status: status, startedAt: Self.runEpoch)
    }

    private func state(entry: ProcessEntry, runs: [ProcessRun] = []) -> WorkspaceState {
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp/u5")],
            processEntries: [entry],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS",
                                   tabIds: entry.isArchived ? [] : [Self.entryId])],
            processRuns: runs)
    }

    private func loaded(_ m: WorkbenchViewModel, fallback: ProcessEntry) -> ProcessEntry {
        m.state.processEntries.first ?? fallback
    }

    // MARK: - L9321 — drive the Restore button ACTION (archived arm)

    func testStatusBar_restoreTap_restoresEntry() throws {
        let e = entry(isArchived: true)
        let m = try makeVM(state: state(entry: e))
        let le = loaded(m, fallback: e)
        XCTAssertTrue(le.isArchived, "provenance: archived → the Restore button arm")
        let bar = SessionStatusBar(entry: le, model: m)
        // INVOCATION: tap Restore → restoreCustomSession replaces the entry with its
        // restored (non-archived) form.
        try bar.inspect().find(button: "Restore").tap()
        XCTAssertEqual(m.state.processEntries.first?.isArchived, false,
                       "the Restore tap must un-archive the entry in state")
    }

    // MARK: - L9328 — drive the Recover button ACTION (recoverable arm)

    func testStatusBar_recoverTap_setsErrorOnEmptyExecutable() throws {
        // A recoverable entry (trusted + autoResume + needsRecovery) but with an EMPTY
        // executable: the Recover button renders (canRecover), and the tap routes through
        // the command planner which throws `emptyExecutable` → the catch arm sets
        // errorMessage SYNCHRONOUSLY (no Task / no process spawn).
        let e = entry(executable: "", autoResume: true)
        let m = try makeVM(state: state(entry: e, runs: [run(.needsRecovery)]))
        let le = loaded(m, fallback: e)
        XCTAssertTrue(m.canRecover(le), "provenance: trusted+autoResume needsRecovery → canRecover")
        XCTAssertEqual(m.recoveryButtonTitle(for: le), "Respawn",
                       "provenance: respawn recovery → the Respawn button title")
        XCTAssertNil(m.errorMessage, "no error before the tap")
        let bar = SessionStatusBar(entry: le, model: m)
        // INVOCATION: tap the recovery button (Label "Respawn") → recover(_:) → the
        // planner throws emptyExecutable → the catch arm sets errorMessage synchronously.
        try bar.inspect().find(button: "Respawn").tap()
        XCTAssertNotNil(m.errorMessage, "the Recover tap must set errorMessage (planner threw)")
        XCTAssertTrue(m.errorMessage?.contains("build") ?? false,
                      "the error names the entry: \(m.errorMessage ?? "nil")")
    }

    // MARK: - L9346 — the non-available executable-health `.orange` arm

    func testStatusBar_missingExecutableHealth_rendersOrangeRow() throws {
        let e = entry()
        let m = try makeVM(state: state(entry: e))
        let le = loaded(m, fallback: e)
        m.executableHealthByEntryID[le.id] = ExecutableHealth(
            executable: "/bin/zsh", status: .missing, detail: "not found on PATH")
        let bar = SessionStatusBar(entry: le, model: m)
        let tree = try ViewSnapshotHost.snapshotText(of: bar)
        XCTAssertTrue(tree.contains(#"text="Executable: not found on PATH""#),
                      "the non-available executable-health row renders:\n\(tree)")
        try assertViewSnapshot(of: bar, named: "SessionStatusBar.missingExecutable")
    }

    // MARK: - Negative controls (P2 mutation-verified — the tap side-effects)

    func testStatusBar_negativeControl_restoreFlipsArchivedState() throws {
        // Before tap: archived. After tap: not archived. The state mutation is the guard.
        let e = entry(isArchived: true)
        let m = try makeVM(state: state(entry: e))
        let le = loaded(m, fallback: e)
        XCTAssertTrue(m.state.processEntries.first?.isArchived ?? false, "archived before")
        try SessionStatusBar(entry: le, model: m).inspect().find(button: "Restore").tap()
        XCTAssertFalse(m.state.processEntries.first?.isArchived ?? true, "not archived after")
    }

    func testStatusBar_missingExecutableHealth_deterministicNoLeak() throws {
        func make() throws -> String {
            let e = entry()
            let m = try makeVM(state: state(entry: e))
            let le = loaded(m, fallback: e)
            m.executableHealthByEntryID[le.id] = ExecutableHealth(
                executable: "/bin/zsh", status: .missing, detail: "not found on PATH")
            return try ViewSnapshotHost.snapshotText(of: SessionStatusBar(entry: le, model: m))
        }
        let a = try make(); let b = try make()
        XCTAssertEqual(a, b, "must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no /Users/ leak:\n\(a)")
        XCTAssertFalse(a.contains("/var/folders/"), "no temp-dir leak:\n\(a)")
    }
}
#endif
