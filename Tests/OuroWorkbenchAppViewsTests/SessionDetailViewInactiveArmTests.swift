#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C0 SU-6 — the **live-terminal-arm carve-out** recipe (edge-case playbook #6 /
/// allowlist-candidate #3). `SessionDetailView` (`:8477`) branches `if let session =
/// model.activeSession(for: entry)` → the LIVE arm embeds `TerminalPane(session:)` (the
/// live PTY view, `@main`-allowlisted, outside coverage) `else` → `InactiveTerminalSurface`.
/// The LIVE arm is NON-snapshottable (no live session in-process); we carve it out
/// (allowlist) and snapshot the INACTIVE arm via the REAL seam: a VM with NO launched
/// session → `model.activeSession(for:) == nil` → the `else` branch renders.
///
/// **Path-leak (verified first-hand):** the inactive arm's `InactiveTerminalSurface`
/// renders `Text(model.launchCommand(for: entry))` (`:9381`), composed from the entry's
/// `executable` + `workingDirectory` → a machine path if the working dir is real. **The
/// fixture pins it:** a FIXED `/tmp/u4` working directory (the SU3 `/tmp/su3` precedent),
/// defended by `!tree.contains("/Users/")`.
///
/// **Provenance (P2).** The VM is built via the `makeVM` dual-injection store seam (AN-001
/// temp `agentBundlesURL`); the `ProcessEntry` is persisted + loaded through the real store
/// (the same provenance as `SidebarSurfaceStateSetTests`). No live session is ever launched,
/// so `activeSession(for:) == nil` is the GENUINE state the seam produces (not a fabricated
/// unreachable arm — the AN-006/C1 discipline).
///
/// **Enumerated state-set (the inactive arm's data-driven branches):**
///   - `readyToLaunch` — a `.shell`, not archived, no recoverable run → "Ready to launch"
///       headline + the launch-command row + the "Launch" button.
///   - `archived` — the SAME entry archived → "Archived" headline + archivebox glyph +
///       the "Restore" button (the `isArchived` arm).
@MainActor
final class SessionDetailViewInactiveArmTests: XCTestCase {

    private static let entryId = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
    private static let wsId = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c0inactive-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    /// A fixed `.shell` entry with a FIXED `/tmp/u4` working dir (the path-leak fix — the
    /// launch command renders this verbatim).
    private func entry(isArchived: Bool = false) -> ProcessEntry {
        ProcessEntry(
            id: Self.entryId, projectId: Self.projectId, name: "build",
            kind: .shell, executable: "/bin/zsh", workingDirectory: "/tmp/u4",
            isArchived: isArchived
        )
    }

    private func state(entry: ProcessEntry) -> WorkspaceState {
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            processEntries: [entry],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: entry.isArchived ? [] : [Self.entryId])]
        )
    }

    private func detail(for entry: ProcessEntry) throws -> SessionDetailView {
        let model = try makeVM(state: state(entry: entry))
        let loaded = model.state.processEntries.first ?? entry
        return SessionDetailView(entry: loaded, model: model)
    }

    // MARK: - Enumerated state-set (the carve-out: only the INACTIVE arm)

    func testDetail_readyToLaunch_inactiveArm() throws {
        let e = entry()
        let view = try detail(for: e)
        // The carve-out invariant: no live session → the inactive arm renders, the live
        // `TerminalPane` arm is never constructed (allowlisted).
        XCTAssertNil(view.model.activeSession(for: e),
                     "carve-out: no live session → the inactive arm is the rendered branch")
        try assertViewSnapshot(of: view, named: "SessionDetailView.readyToLaunch")
    }

    func testDetail_archived_inactiveArm() throws {
        let e = entry(isArchived: true)
        let view = try detail(for: e)
        XCTAssertNil(view.model.activeSession(for: e), "carve-out: no live session")
        XCTAssertTrue(view.entry.isArchived, "provenance: archived → the Archived/Restore arm")
        try assertViewSnapshot(of: view, named: "SessionDetailView.archived")
    }

    // MARK: - Path-leak defense (P3 — the inactive arm renders the launch command)

    /// `InactiveTerminalSurface` renders `Text(model.launchCommand(for: entry))` (built from
    /// the entry's executable + working directory). The fixed `/tmp/u4` working dir is the
    /// ONLY thing keeping a machine path out of the tree — assert it directly.
    func testDetail_pathLeakDefense_noMachinePathInTree() throws {
        for archived in [false, true] {
            let tree = try ViewSnapshotHost.snapshotText(of: try detail(for: entry(isArchived: archived)))
            XCTAssertFalse(tree.contains("/Users/"), "no /Users/ machine-path leak:\n\(tree)")
            XCTAssertFalse(tree.contains("/var/folders/"), "no temp-dir path leak:\n\(tree)")
        }
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The `isArchived` flag flips the inactive arm's headline + primary button
    /// (Launch ↔ Restore), a real entry-driven branch.
    func testDetail_negativeControl_archivedFlipsInactiveArm() throws {
        let ready = try ViewSnapshotHost.snapshotText(of: try detail(for: entry()))
        let archived = try ViewSnapshotHost.snapshotText(of: try detail(for: entry(isArchived: true)))
        XCTAssertNotEqual(ready, archived, "the archived flag must flip the inactive arm")
        XCTAssertTrue(ready.contains("Ready to launch"), "ready: the launch headline:\n\(ready)")
        XCTAssertTrue(ready.contains("Launch"), "ready: the Launch button:\n\(ready)")
        XCTAssertTrue(archived.contains("Archived"), "archived: the Archived headline:\n\(archived)")
        XCTAssertTrue(archived.contains("Restore"), "archived: the Restore button:\n\(archived)")
        XCTAssertFalse(archived.contains("Ready to launch"), "archived: not the launch headline:\n\(archived)")
    }

    // MARK: - Class 6 — the showsInspector / showsTranscriptSheet arms, DRIVEN via the init seam

    /// `initialShowsInspector: true` (no live session → the inactive arm stays the body) seeds
    /// the @State so the `if showsInspector` SessionInspectorPanel + Divider arm renders. The
    /// disclosure chevron points DOWN (collapsed: RIGHT) and the inspector adds its pill row.
    func testDetail_inspectorArm_expandedRendersInspectorPanel() throws {
        let e = entry()
        let model = try makeVM(state: state(entry: e))
        let loaded = model.state.processEntries.first ?? e
        let view = SessionDetailView(entry: loaded, model: model, initialShowsInspector: true)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"image="chevron.down""#),
                      "expanded: the disclosure chevron points down:\n\(tree)")
        // The SessionInspectorPanel adds a SECOND trust/auto-resume pill row (the title strip
        // already carries one), so the expanded tree has the inspector's pills duplicated.
        let trustCount = tree.components(separatedBy: #"text="trusted""#).count - 1
        XCTAssertGreaterThanOrEqual(trustCount, 2,
                                    "expanded: the inspector's trust pill is added (≥2 total):\n\(tree)")
    }

    /// The showsInspector gate flips the tree (negative control): the inspector adds nodes, so
    /// the expanded tree differs AND carries the down chevron the collapsed one lacks.
    func testDetail_inspectorArm_gateFlipsTree() throws {
        let e = entry()
        let collapsed = try ViewSnapshotHost.snapshotText(of: try detail(for: e))
        let model = try makeVM(state: state(entry: e))
        let loaded = model.state.processEntries.first ?? e
        let expanded = try ViewSnapshotHost.snapshotText(
            of: SessionDetailView(entry: loaded, model: model, initialShowsInspector: true))
        XCTAssertNotEqual(collapsed, expanded, "the showsInspector gate must flip the tree")
        XCTAssertTrue(collapsed.contains(#"image="chevron.right""#), "collapsed: the chevron points right")
        XCTAssertTrue(expanded.contains(#"image="chevron.down""#), "expanded: the chevron points down")
        XCTAssertFalse(collapsed.contains(#"image="chevron.down""#), "collapsed: never the down chevron")
    }

    /// `initialShowsTranscriptSheet: true` seeds the @State so the
    /// `.sheet(isPresented: $showsTranscriptSheet) { SessionTranscriptSheet }` arm is presented.
    func testDetail_transcriptSheetArm_expandedPresentsSheet() throws {
        let e = entry()
        let model = try makeVM(state: state(entry: e))
        let loaded = model.state.processEntries.first ?? e
        let view = SessionDetailView(entry: loaded, model: model, initialShowsTranscriptSheet: true)
        // Rendering with the sheet flag set drives the `.sheet(isPresented:)` content closure;
        // a render that includes the transcript sheet must not throw or leak a path.
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertFalse(tree.contains("/Users/"), "no machine-path leak in the transcript-sheet render:\n\(tree)")
    }

    // MARK: - Determinism (P3)

    func testDetail_determinism_byteIdenticalTwiceAndNoLeak() throws {
        for archived in [false, true] {
            let a = try ViewSnapshotHost.snapshotText(of: try detail(for: entry(isArchived: archived)))
            let b = try ViewSnapshotHost.snapshotText(of: try detail(for: entry(isArchived: archived)))
            XCTAssertEqual(a, b, "must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
        }
    }
}
#endif
