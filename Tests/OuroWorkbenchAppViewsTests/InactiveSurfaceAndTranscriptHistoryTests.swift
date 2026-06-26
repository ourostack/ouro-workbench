#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C9-2 — the INACTIVE-surface recovery state machine + the transcript/status/management
/// leaves of the session-detail family.
///
/// C0's `SessionDetailViewInactiveArmTests` covered `SessionDetailView` at the
/// `readyToLaunch` / `archived` arms (the live-`TerminalPane`-arm carve template). This unit
/// covers the REMAINING C9 inactive-arm surfaces and their data-driven branches:
///
///   - `InactiveTerminalSurface` (`:9395`) — the recovery STATE MACHINE: `archived` /
///     `manualRecoveryNeeded` ("No resumable session" → Start fresh) / `canRecover`
///     ("Ready to recover" → Recover) / plain `readyToLaunch`, driven by the REAL
///     `RecoveryPlanner` off each entry's latest `ProcessRun.status`. Plus the
///     `if let health` executable-health row and the `if let tail` transcript-preview branch.
///   - `TranscriptHistoryView` (`:9886`) — **path-leak vector #2**: renders `Text(tail.path)`
///     VERBATIM + the `if tail.truncated` "tail" pill. (The review gate moved this OUT of the
///     branchless bin → it is logic-bearing/C9.)
///   - `SessionStatusBar` (`:9277`) — the archived/recoverable ternary + the `if let health` row.
///   - `CustomSessionManagementBar` (`:9325`) — the `if entry.isArchived` Restore/Archive flip
///     + the `ForEach(projects)` Move menu.
///
/// **Provenance (P2).** `processRuns` drive the planner (the SU-D precedent): a TRUSTED +
/// `autoResume` `.shell` `.needsRecovery` run → `.respawn` (`canRecover`); a TRUSTED entry whose
/// latest run is `.manualActionNeeded` → `.manualActionNeeded` (`manualRecoveryNeeded`); no run →
/// the plain ready arm. `TranscriptTail` is built by writing a REAL transcript file at a FIXED
/// `/tmp/ouro-c9` path (vector #2 — `tail.path` renders verbatim, so it MUST be deterministic +
/// leak-free).
///
/// **Path-leak (P3).** `launchCommand` cwd pinned to `/tmp/u4`; `tail.path` pinned to the fixed
/// `/tmp/ouro-c9` file. Defended by `!tree.contains("/Users/")` / `!tree.contains("/var/folders/")`.
@MainActor
final class InactiveSurfaceAndTranscriptHistoryTests: XCTestCase {

    private static let entryId = UUID(uuidString: "C9000002-0000-0000-0000-000000000001")!
    private static let projectId = UUID(uuidString: "C9000002-0000-0000-0000-0000000000A1")!
    private static let altProjectId = UUID(uuidString: "C9000002-0000-0000-0000-0000000000A2")!
    private static let wsId = UUID(uuidString: "C90000A2-0000-0000-0000-0000000000A1")!
    private static let runEpoch = Date(timeIntervalSince1970: 1_700_000_000)
    private static let fixedTranscriptPath = "/tmp/ouro-c9/history.log"

    // MARK: - Hermetic provenance fixture (AN-001-safe)

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c9-2-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private func entry(
        isArchived: Bool = false,
        trust: ProcessTrust = .trusted,
        autoResume: Bool = false,
        lastSummary: String? = nil,
        projectId: UUID? = nil
    ) -> ProcessEntry {
        ProcessEntry(
            id: Self.entryId, projectId: projectId ?? Self.projectId, name: "build",
            kind: .shell, executable: "/bin/zsh", workingDirectory: "/tmp/u4",
            trust: trust, autoResume: autoResume, isArchived: isArchived, lastSummary: lastSummary
        )
    }

    private func run(_ status: ProcessStatus, transcriptPath: String? = nil) -> ProcessRun {
        ProcessRun(
            id: UUID(uuidString: "C9000002-0000-0000-0000-0000000000F1")!,
            entryId: Self.entryId, status: status, startedAt: Self.runEpoch,
            transcriptPath: transcriptPath
        )
    }

    private func state(
        entry: ProcessEntry,
        runs: [ProcessRun] = [],
        projects: [WorkbenchProject]? = nil
    ) -> WorkspaceState {
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: projects ?? [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp/u4")],
            processEntries: [entry],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: entry.isArchived ? [] : [Self.entryId])],
            processRuns: runs
        )
    }

    private func loaded(_ model: WorkbenchViewModel, fallback: ProcessEntry) -> ProcessEntry {
        model.state.processEntries.first ?? fallback
    }

    // MARK: - InactiveTerminalSurface — the recovery state machine

    private func surface(_ model: WorkbenchViewModel, entry: ProcessEntry) -> InactiveTerminalSurface {
        InactiveTerminalSurface(entry: entry, model: model, onShowTranscript: {})
    }

    func testSurface_readyToLaunch() throws {
        let e = entry()
        let m = try makeVM(state: state(entry: e))
        let le = loaded(m, fallback: e)
        XCTAssertFalse(m.canRecover(le)); XCTAssertFalse(m.manualRecoveryNeeded(for: le))
        try assertViewSnapshot(of: surface(m, entry: le), named: "InactiveTerminalSurface.readyToLaunch")
    }

    func testSurface_canRecover() throws {
        // TRUSTED + autoResume .shell whose latest run .needsRecovery → .respawn → canRecover.
        let e = entry(autoResume: true)
        let m = try makeVM(state: state(entry: e, runs: [run(.needsRecovery)]))
        let le = loaded(m, fallback: e)
        XCTAssertTrue(m.canRecover(le), "provenance: trusted+autoResume needsRecovery → canRecover")
        try assertViewSnapshot(of: surface(m, entry: le), named: "InactiveTerminalSurface.canRecover")
    }

    func testSurface_manualRecoveryNeeded() throws {
        // TRUSTED entry whose latest run is .manualActionNeeded → manualRecoveryNeeded
        // ("No resumable session" headline + Start fresh).
        let e = entry()
        let m = try makeVM(state: state(entry: e, runs: [run(.manualActionNeeded)]))
        let le = loaded(m, fallback: e)
        XCTAssertTrue(m.manualRecoveryNeeded(for: le), "provenance: manualActionNeeded → Start-fresh arm")
        try assertViewSnapshot(of: surface(m, entry: le), named: "InactiveTerminalSurface.manualRecovery")
    }

    func testSurface_archived() throws {
        let e = entry(isArchived: true)
        let m = try makeVM(state: state(entry: e))
        let le = loaded(m, fallback: e)
        XCTAssertTrue(le.isArchived)
        try assertViewSnapshot(of: surface(m, entry: le), named: "InactiveTerminalSurface.archived")
    }

    func testSurface_withTranscriptPreview() throws {
        // A real transcript file → the if-let-tail TranscriptRehydrationPreview branch.
        let e = entry()
        try writeTranscript(text: "where you left off\n", truncated: false)
        let m = try makeVM(state: state(entry: e, runs: [run(.exited, transcriptPath: Self.fixedTranscriptPath)]))
        let le = loaded(m, fallback: e)
        XCTAssertNotNil(m.transcriptTail(for: le), "provenance: real transcript → the preview branch")
        try assertViewSnapshot(of: surface(m, entry: le), named: "InactiveTerminalSurface.withTranscript")
    }

    /// The recovery state machine flips the surface headline + primary button across the
    /// reachable inactive states — non-vacuity proof (the captured node flips).
    func testSurface_negativeControl_recoveryStateFlipsHeadlineAndButton() throws {
        func tree(_ make: () throws -> InactiveTerminalSurface) throws -> String {
            try ViewSnapshotHost.snapshotText(of: try make())
        }
        let ready = try tree {
            let e = entry(); let m = try makeVM(state: state(entry: e)); return surface(m, entry: loaded(m, fallback: e))
        }
        let recover = try tree {
            let e = entry(autoResume: true)
            let m = try makeVM(state: state(entry: e, runs: [run(.needsRecovery)]))
            return surface(m, entry: loaded(m, fallback: e))
        }
        let manual = try tree {
            let e = entry()
            let m = try makeVM(state: state(entry: e, runs: [run(.manualActionNeeded)]))
            return surface(m, entry: loaded(m, fallback: e))
        }
        XCTAssertNotEqual(ready, recover, "needsRecovery flips the surface")
        XCTAssertNotEqual(recover, manual, "manualActionNeeded flips the surface")
        // The three reachable inactive states each carry a distinct primary button — the
        // load-bearing captured node the recovery state machine flips. (The recover-arm
        // headline is a model-derived recovery summary; the button is the stable signal.)
        XCTAssertTrue(ready.contains(#"text="Ready to launch""#), "ready: launch headline:\n\(ready)")
        XCTAssertTrue(ready.contains(#"text="Launch""#), "ready: the Launch button:\n\(ready)")
        XCTAssertTrue(recover.contains(#"text="Respawn""#), "recover: the Respawn recovery button:\n\(recover)")
        XCTAssertTrue(manual.contains(#"text="No resumable session""#), "manual: no-resumable headline:\n\(manual)")
        XCTAssertTrue(manual.contains(#"text="Start fresh""#), "manual: Start-fresh button:\n\(manual)")
        XCTAssertFalse(ready.contains("Start fresh"), "ready: no Start-fresh:\n\(ready)")
        XCTAssertFalse(ready.contains(#"text="Respawn""#), "ready: no Respawn button:\n\(ready)")
    }

    // MARK: - TranscriptHistoryView — path-leak vector #2 + truncated pill

    func testHistory_notTruncated() throws {
        let tail = TranscriptTail(path: Self.fixedTranscriptPath, text: "line one\nline two\n", truncated: false)
        try assertViewSnapshot(of: TranscriptHistoryView(tail: tail), named: "TranscriptHistoryView.full")
    }

    func testHistory_truncated() throws {
        let tail = TranscriptTail(path: Self.fixedTranscriptPath, text: "…older\nline two\n", truncated: true)
        try assertViewSnapshot(of: TranscriptHistoryView(tail: tail), named: "TranscriptHistoryView.truncated")
    }

    /// `if tail.truncated` adds the "tail" pill; the path renders verbatim. Both are
    /// captured nodes → non-vacuity + the leak-vector proof.
    func testHistory_negativeControl_truncatedPillAndPathFlipTree() throws {
        let full = try ViewSnapshotHost.snapshotText(of: TranscriptHistoryView(
            tail: TranscriptTail(path: Self.fixedTranscriptPath, text: "body\n", truncated: false)))
        let truncated = try ViewSnapshotHost.snapshotText(of: TranscriptHistoryView(
            tail: TranscriptTail(path: Self.fixedTranscriptPath, text: "body\n", truncated: true)))
        XCTAssertNotEqual(full, truncated, "the truncated pill must flip the tree")
        XCTAssertFalse(full.contains(#"text="tail""#), "not truncated: no tail pill:\n\(full)")
        XCTAssertTrue(truncated.contains(#"text="tail""#), "truncated: the tail pill:\n\(truncated)")

        // The path renders verbatim (vector #2) — a different path must change the tree.
        let altPath = try ViewSnapshotHost.snapshotText(of: TranscriptHistoryView(
            tail: TranscriptTail(path: "/tmp/ouro-c9/other.log", text: "body\n", truncated: false)))
        XCTAssertNotEqual(full, altPath, "the rendered tail.path must drive the tree (vector #2 is real)")
        XCTAssertTrue(altPath.contains("/tmp/ouro-c9/other.log"), altPath)
    }

    func testHistory_pathLeakDefense_noMachinePathInTree() throws {
        for truncated in [false, true] {
            let tree = try ViewSnapshotHost.snapshotText(of: TranscriptHistoryView(
                tail: TranscriptTail(path: Self.fixedTranscriptPath, text: "x\n", truncated: truncated)))
            XCTAssertTrue(tree.contains(Self.fixedTranscriptPath), "the fixed path renders verbatim:\n\(tree)")
            XCTAssertFalse(tree.contains("/Users/"), "no /Users/ leak:\n\(tree)")
            XCTAssertFalse(tree.contains("/var/folders/"), "no temp-UUID leak:\n\(tree)")
        }
    }

    // MARK: - SessionStatusBar

    private func statusBar(_ model: WorkbenchViewModel, entry: ProcessEntry) -> SessionStatusBar {
        SessionStatusBar(entry: entry, model: model)
    }

    func testStatusBar_configured() throws {
        let e = entry()
        let m = try makeVM(state: state(entry: e))
        let le = loaded(m, fallback: e)
        try assertViewSnapshot(of: statusBar(m, entry: le), named: "SessionStatusBar.configured")
    }

    func testStatusBar_recoverable() throws {
        let e = entry(autoResume: true)
        let m = try makeVM(state: state(entry: e, runs: [run(.needsRecovery)]))
        let le = loaded(m, fallback: e)
        XCTAssertTrue(m.canRecover(le), "provenance: recoverable → the Recover button arm")
        try assertViewSnapshot(of: statusBar(m, entry: le), named: "SessionStatusBar.recoverable")
    }

    func testStatusBar_archived() throws {
        let e = entry(isArchived: true)
        let m = try makeVM(state: state(entry: e))
        let le = loaded(m, fallback: e)
        try assertViewSnapshot(of: statusBar(m, entry: le), named: "SessionStatusBar.archived")
    }

    /// The archived/recoverable branch flips the status bar's headline + button.
    func testStatusBar_negativeControl_archivedFlipsTree() throws {
        let configured = try ViewSnapshotHost.snapshotText(of: { () -> SessionStatusBar in
            let e = entry(); let m = try makeVM(state: state(entry: e)); return statusBar(m, entry: loaded(m, fallback: e))
        }())
        let archived = try ViewSnapshotHost.snapshotText(of: { () -> SessionStatusBar in
            let e = entry(isArchived: true); let m = try makeVM(state: state(entry: e)); return statusBar(m, entry: loaded(m, fallback: e))
        }())
        XCTAssertNotEqual(configured, archived, "archived must flip the status bar")
        XCTAssertTrue(archived.contains(#"text="Archived""#), "archived: the Archived headline:\n\(archived)")
        XCTAssertTrue(archived.contains(#"text="Restore""#), "archived: the Restore button:\n\(archived)")
        XCTAssertFalse(configured.contains(#"text="Restore""#), "configured: no Restore:\n\(configured)")
    }

    // MARK: - CustomSessionManagementBar

    private func managementBar(_ model: WorkbenchViewModel, entry: ProcessEntry) -> CustomSessionManagementBar {
        CustomSessionManagementBar(entry: entry, model: model)
    }

    func testManagementBar_active_showsArchive() throws {
        let e = entry()
        let m = try makeVM(state: state(entry: e))
        let le = loaded(m, fallback: e)
        XCTAssertFalse(le.isArchived, "provenance: not archived → the Archive button arm")
        try assertViewSnapshot(of: managementBar(m, entry: le), named: "CustomSessionManagementBar.active")
    }

    func testManagementBar_archived_showsRestore() throws {
        let e = entry(isArchived: true)
        let m = try makeVM(state: state(entry: e))
        let le = loaded(m, fallback: e)
        try assertViewSnapshot(of: managementBar(m, entry: le), named: "CustomSessionManagementBar.archived")
    }

    /// The `if entry.isArchived` Restore/Archive branch flips the management bar.
    func testManagementBar_negativeControl_archivedFlipsTree() throws {
        let active = try ViewSnapshotHost.snapshotText(of: { () -> CustomSessionManagementBar in
            let e = entry(); let m = try makeVM(state: state(entry: e)); return managementBar(m, entry: loaded(m, fallback: e))
        }())
        let archived = try ViewSnapshotHost.snapshotText(of: { () -> CustomSessionManagementBar in
            let e = entry(isArchived: true); let m = try makeVM(state: state(entry: e)); return managementBar(m, entry: loaded(m, fallback: e))
        }())
        XCTAssertNotEqual(active, archived, "archived must flip the management bar")
        XCTAssertTrue(active.contains(#"text="Archive""#), "active: the Archive button:\n\(active)")
        XCTAssertFalse(active.contains(#"text="Restore""#), "active: no Restore:\n\(active)")
        XCTAssertTrue(archived.contains(#"text="Restore""#), "archived: the Restore button:\n\(archived)")
        XCTAssertFalse(archived.contains(#"text="Archive""#), "archived: no Archive:\n\(archived)")
    }

    // MARK: - Determinism (P3)

    func testC9_2_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, () throws -> String)] = [
            ("surface.canRecover", {
                let e = self.entry(autoResume: true)
                let m = try self.makeVM(state: self.state(entry: e, runs: [self.run(.needsRecovery)]))
                return try ViewSnapshotHost.snapshotText(of: self.surface(m, entry: self.loaded(m, fallback: e)))
            }),
            ("history.truncated", {
                try ViewSnapshotHost.snapshotText(of: TranscriptHistoryView(
                    tail: TranscriptTail(path: Self.fixedTranscriptPath, text: "x\n", truncated: true)))
            }),
            ("statusBar.recoverable", {
                let e = self.entry(autoResume: true)
                let m = try self.makeVM(state: self.state(entry: e, runs: [self.run(.needsRecovery)]))
                return try ViewSnapshotHost.snapshotText(of: self.statusBar(m, entry: self.loaded(m, fallback: e)))
            }),
            ("managementBar.active", {
                let e = self.entry()
                let m = try self.makeVM(state: self.state(entry: e))
                return try ViewSnapshotHost.snapshotText(of: self.managementBar(m, entry: self.loaded(m, fallback: e)))
            })
        ]
        for (name, make) in cases {
            let a = try make(); let b = try make()
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
            XCTAssertFalse(a.contains("/var/folders/"), "\(name): no temp-UUID leak:\n\(a)")
        }
    }

    // MARK: - Transcript-file fixture helper (fixed /tmp path — leak-free, deterministic)

    private func writeTranscript(text: String, truncated _: Bool) throws {
        let file = URL(fileURLWithPath: Self.fixedTranscriptPath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.data(using: .utf8)!.write(to: file)
    }
}
#endif
