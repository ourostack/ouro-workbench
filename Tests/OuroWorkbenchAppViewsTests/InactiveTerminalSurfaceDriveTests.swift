#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B5 — `InactiveTerminalSurface` (`:9426`) close-out. C9 drove the recovery-state-machine
/// RENDER arms (archived / manualRecovery / canRecover / ready headlines + transcript preview)
/// but carved the button ACTIONS, the `Ready to recover` headline arm, the executable-health
/// label arm, and the `onShowTranscript` default-arg. The 11 uncovered:
///   - `L9429:40` — the `onShowTranscript: () -> Void = {}` default autoclosure;
///   - `L9448:29` — the `canRecover ? "Ready to recover" : …` headline (recover arm);
///   - `L9495:28` — Restore ACTION; `L9504:28` — Start-fresh ACTION;
///   - `L9512:28`/`L9513:28`/`L9513:39`/`L9515:32` — the Launch/Recover button + its
///     `if canRecover { recover } else { launch }` arms + the `canRecover ? title : "Launch"` label;
///   - `L9538:24` — Copy-launch-command ACTION;
///   - `L9550:106`/`L9554:14` — the `if !isArchived, let health, health.status != .available`
///     executable-health label arm.
///
/// DRIVEN: button ACTIONS via `.tap()` — Restore→un-archived, Start-fresh→`pendingStartFresh`,
/// Launch/Recover→`errorMessage` (EMPTY-executable → planner throws synchronously, no spawn),
/// Copy→`state.actionLog`. The recover-headline + health-label arms via real seams. The default
/// autoclosure by constructing the view WITHOUT `onShowTranscript`.
@MainActor
final class InactiveTerminalSurfaceDriveTests: XCTestCase {

    private static let entryId = UUID(uuidString: "B515AC71-0000-0000-0000-0000000000E1")!
    private static let projectId = UUID(uuidString: "B515AC71-0000-0000-0000-0000000000A1")!
    private static let wsId = UUID(uuidString: "B515AC71-0000-0000-0000-0000000000B1")!
    private static let runEpoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b5inactive-\(UUID().uuidString)", isDirectory: true)
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
        ProcessRun(id: UUID(uuidString: "B515AC71-0000-0000-0000-0000000000F1")!,
                   entryId: Self.entryId, status: status, startedAt: Self.runEpoch)
    }

    private func state(entry: ProcessEntry, runs: [ProcessRun] = []) -> WorkspaceState {
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp/u5")],
            processEntries: [entry],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: entry.isArchived ? [] : [Self.entryId])],
            processRuns: runs)
    }

    private func loaded(_ m: WorkbenchViewModel, fallback: ProcessEntry) -> ProcessEntry {
        m.state.processEntries.first ?? fallback
    }

    private func surface(_ m: WorkbenchViewModel, entry e: ProcessEntry) -> InactiveTerminalSurface {
        InactiveTerminalSurface(entry: e, model: m, onShowTranscript: {})
    }

    // MARK: - L9448 — the "Ready to recover" headline arm

    /// A recoverable entry whose `lastSummary` is empty. The StartupRecoveryReconciler sets a
    /// summary for an autoResume recoverable run during VM startup, so to reach the
    /// `canRecover ? "Ready to recover"` headline arm we drive the genuinely-producible state of
    /// a recoverable entry with no summary: clear the loaded entry's `lastSummary` (the recovery
    /// plan is keyed by entry id, so `canRecover` stays true) → the headline falls through to
    /// L9448. An entry with no summary is a real state (a brand-new recoverable session).
    func testSurface_canRecoverNoSummary_readyToRecoverHeadline() throws {
        let e = entry(autoResume: true)
        let m = try makeVM(state: state(entry: e, runs: [run(.needsRecovery)]))
        var le = loaded(m, fallback: e)
        le.lastSummary = nil
        XCTAssertTrue(m.canRecover(le), "the recovery plan is keyed by id → canRecover stays true")
        XCTAssertNil(le.lastSummary, "the entry value has no summary")
        let tree = try ViewSnapshotHost.snapshotText(of: surface(m, entry: le))
        XCTAssertTrue(tree.contains(#"text="Ready to recover""#),
                      "the canRecover headline arm (L9448):\n\(tree)")
        try assertViewSnapshot(of: surface(m, entry: le), named: "InactiveTerminalSurface.readyToRecover")
    }

    // MARK: - L9550/9554 — the executable-health label arm

    func testSurface_missingExecutableHealth_rendersLabel() throws {
        let e = entry()
        let m = try makeVM(state: state(entry: e))
        let le = loaded(m, fallback: e)
        m.executableHealthByEntryID[le.id] = ExecutableHealth(
            executable: "/bin/zsh", status: .missing, detail: "not found on PATH")
        let tree = try ViewSnapshotHost.snapshotText(of: surface(m, entry: le))
        XCTAssertTrue(tree.contains(#"text="Executable: not found on PATH""#),
                      "the executable-health label arm (L9550/9554):\n\(tree)")
        try assertViewSnapshot(of: surface(m, entry: le), named: "InactiveTerminalSurface.missingExecutable")
    }

    // MARK: - L9429 — the default onShowTranscript autoclosure

    func testSurface_defaultOnShowTranscript_constructsWithoutClosure() throws {
        // Construct WITHOUT onShowTranscript → the `= {}` default-arg autoclosure runs.
        let e = entry()
        let m = try makeVM(state: state(entry: e))
        let le = loaded(m, fallback: e)
        let view = InactiveTerminalSurface(entry: le, model: m)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="Ready to launch""#), "renders with the default closure:\n\(tree)")
    }

    // MARK: - L9495 — Restore ACTION (archived)

    func testSurface_restoreTap_restoresEntry() throws {
        let e = entry(isArchived: true)
        let m = try makeVM(state: state(entry: e))
        let le = loaded(m, fallback: e)
        try surface(m, entry: le).inspect().find(button: "Restore").tap()
        XCTAssertFalse(m.state.processEntries.first?.isArchived ?? true, "Restore tap → un-archived")
    }

    // MARK: - L9504 — Start-fresh ACTION (manualRecoveryNeeded)

    func testSurface_startFreshTap_setsPendingStartFresh() throws {
        let e = entry()
        let m = try makeVM(state: state(entry: e, runs: [run(.manualActionNeeded)]))
        let le = loaded(m, fallback: e)
        XCTAssertTrue(m.manualRecoveryNeeded(for: le), "provenance: manualActionNeeded → Start-fresh arm")
        XCTAssertNil(m.pendingStartFresh, "no pending start-fresh before tap")
        try surface(m, entry: le).inspect().find(button: "Start fresh").tap()
        XCTAssertEqual(m.pendingStartFresh?.id, le.id, "Start-fresh tap → requestStartFresh sets pendingStartFresh")
    }

    // MARK: - L9512/9513:39/9515 — the Launch button ACTION (else arm → launch)

    func testSurface_launchTap_setsErrorOnEmptyExecutable() throws {
        // A plain ready entry (no run, not recoverable) with EMPTY executable → the Launch
        // button; tapping → launch → launchPlan throws emptyExecutable → errorMessage (no spawn).
        let e = entry(executable: "")
        let m = try makeVM(state: state(entry: e))
        let le = loaded(m, fallback: e)
        XCTAssertFalse(m.canRecover(le)); XCTAssertFalse(m.manualRecoveryNeeded(for: le))
        XCTAssertNil(m.errorMessage)
        try surface(m, entry: le).inspect().find(button: "Launch").tap()
        XCTAssertNotNil(m.errorMessage, "Launch tap on empty executable → errorMessage (planner threw)")
    }

    // MARK: - L9513:28 — the Recover button ACTION (canRecover → recover)

    func testSurface_recoverTap_setsErrorOnEmptyExecutable() throws {
        let e = entry(executable: "", autoResume: true)
        let m = try makeVM(state: state(entry: e, runs: [run(.needsRecovery)]))
        let le = loaded(m, fallback: e)
        XCTAssertTrue(m.canRecover(le), "provenance: recoverable → the recover arm")
        XCTAssertNil(m.errorMessage)
        // The recover button label is the recovery title (e.g. "Respawn").
        let title = m.recoveryButtonTitle(for: le)
        try surface(m, entry: le).inspect().find(button: title).tap()
        XCTAssertNotNil(m.errorMessage, "Recover tap on empty executable → errorMessage (planner threw)")
    }

    // MARK: - L9538 — Copy-launch-command ACTION

    func testSurface_copyLaunchTap_recordsActionLog() throws {
        let e = entry()
        let m = try makeVM(state: state(entry: e))
        let le = loaded(m, fallback: e)
        let before = m.state.actionLog.count
        // The copy button has no text label (image only) — find it by its help/role; use the
        // image-only button via its accessibility. It's the only borderless image button here.
        try surface(m, entry: le).inspect().find(ViewType.Button.self, where: { b in
            (try? b.labelView().image().actualImage().name()) == "doc.on.doc"
        }).tap()
        XCTAssertEqual(m.state.actionLog.count, before + 1, "Copy tap → copyLaunchCommand records an action log entry")
        XCTAssertEqual(m.state.actionLog.first?.action, "copyLaunchCommand")
    }

    // MARK: - Negative controls + determinism

    func testSurface_negativeControl_recoverHeadlineAndHealthFlip() throws {
        let recover = try ViewSnapshotHost.snapshotText(of: { () -> InactiveTerminalSurface in
            let e = entry(autoResume: true); let m = try makeVM(state: state(entry: e, runs: [run(.needsRecovery)]))
            var le = loaded(m, fallback: e); le.lastSummary = nil
            return surface(m, entry: le)
        }())
        let ready = try ViewSnapshotHost.snapshotText(of: { () -> InactiveTerminalSurface in
            let e = entry(); let m = try makeVM(state: state(entry: e))
            return surface(m, entry: loaded(m, fallback: e))
        }())
        XCTAssertNotEqual(recover, ready, "the recover headline must flip vs ready")
        XCTAssertTrue(recover.contains(#"text="Ready to recover""#))
        XCTAssertTrue(ready.contains(#"text="Ready to launch""#))
    }

    func testSurface_deterministic_noLeak() throws {
        func make() throws -> String {
            let e = entry()
            let m = try makeVM(state: state(entry: e))
            let le = loaded(m, fallback: e)
            m.executableHealthByEntryID[le.id] = ExecutableHealth(
                executable: "/bin/zsh", status: .missing, detail: "not found on PATH")
            return try ViewSnapshotHost.snapshotText(of: surface(m, entry: le))
        }
        let a = try make(); let b = try make()
        XCTAssertEqual(a, b, "must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no /Users/ leak:\n\(a)")
        XCTAssertFalse(a.contains("/var/folders/"), "no temp-dir leak:\n\(a)")
    }
}
#endif
