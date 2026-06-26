#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C0 SU-2 — the **standalone menu** recipe (edge-case playbook #5). ViewInspector's
/// synchronous `findAll` does NOT descend a parent's `.contextMenu { }` content, so a
/// context-menu view can never be reached by snapshotting its host row. The named menu
/// views (`TerminalRowContextMenu`, `WorkspaceRowContextMenu`, `WorkspaceTabContextMenu`,
/// `AutonomyStatusPopover`, `BossAgentNamePopover`) are ALL top-level `View` structs
/// (verified first-hand), so we snapshot them STANDALONE via their own initializer —
/// exactly the leaf seam, never by descending a `.contextMenu { }`.
///
/// **Provenance (P2).** The menu's `entry` + `model` are provenance-built via the REAL
/// store seam: `WorkbenchStore(paths:).save(state)` → a fresh `WorkbenchViewModel` whose
/// `load()` reads + migrates the persisted `WorkspaceState`. The menu's data-driven
/// labels then read the SAME model the live app would. AN-001: the VM injects a temp
/// `agentBundlesURL` into BOTH the registrar AND the inventory so no real `~/AgentBundles`
/// scan leaks a machine-local agent name (the `SidebarSurfaceStateSetTests.makeVM` seam).
///
/// **Determinism (P3).** Fixed entry ids + a fixed `/tmp/u4` working directory + a fixed
/// boss name; no clock; byte-identical twice; `!contains("/Users/")`.
///
/// **Enumerated state-set (the menu's data-driven branches):**
///   - `inactiveCustom` — a `.shell` entry (custom), not archived, no live session →
///       "Launch" (vs "Restart"), Pin-to-Top, the full custom block (Edit/Duplicate/
///       Move/Archive/Delete), "Archive Session" (NOT "Restore").
///   - `archivedCustom`  — the SAME entry archived → the custom block's "Restore" arm
///       (vs "Archive Session"); Launch label still "Launch" (no live session).
///   - `nonCustom`       — a `.command` entry (`isCustomSession == false`) → NO custom
///       block at all (Edit/Duplicate/Move/Archive/Delete absent).
@MainActor
final class TerminalRowContextMenuStandaloneTests: XCTestCase {

    // MARK: - Hermetic provenance fixture (AN-001-safe — the makeVM dual-injection seam)

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c0menu-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
    private static let tabId = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
    private static let wsId = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!

    /// A fixed entry; `.shell` is a custom session, `.command` is not.
    private func entry(kind: ProcessKind, isArchived: Bool = false) -> ProcessEntry {
        ProcessEntry(
            id: Self.tabId,
            projectId: Self.projectId,
            name: "build",
            kind: kind,
            executable: "/bin/zsh",
            workingDirectory: "/tmp/u4",
            isArchived: isArchived
        )
    }

    private func state(entry: ProcessEntry) -> WorkspaceState {
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            processEntries: [entry],
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: entry.isArchived ? [] : [Self.tabId])]
        )
    }

    private func menu(for entry: ProcessEntry) throws -> TerminalRowContextMenu {
        let model = try makeVM(state: state(entry: entry))
        // The persisted entry survives load; re-read it through the model so the menu's
        // `entry` is the loaded value (provenance through the real seam).
        let loaded = model.state.processEntries.first ?? entry
        return TerminalRowContextMenu(entry: loaded, model: model)
    }

    /// AN-R2-04 — a menu whose entry HAS a live session. The menu's two active-session
    /// arms (`activeSession(for:) != nil`) read ONLY presence via `activeSessions[id]`, so
    /// we inject a real `TerminalSessionController` built from a real `TerminalCommandPlan`
    /// (the same value type the live `CommandPlanner` emits) WITHOUT calling `start()` — no
    /// process spawns; `transcriptPath: nil` keeps it file-free + path-leak-free. This is a
    /// legitimate model seam (P2 forbids hand-assembling serializer OUTPUT, not injecting a
    /// real controller into the published map the live launch path also writes).
    private func menuWithActiveSession(for entry: ProcessEntry) throws -> (TerminalRowContextMenu, WorkbenchViewModel) {
        let model = try makeVM(state: state(entry: entry))
        let loaded = model.state.processEntries.first ?? entry
        let plan = TerminalCommandPlan(
            entryId: loaded.id,
            executable: "/bin/zsh",
            arguments: [],
            workingDirectory: "/tmp/u4",
            reason: "test active session")
        let controller = try TerminalSessionController(
            plan: plan, onStarted: { _ in }, onOutput: {}, onTerminated: { _ in })
        model.activeSessions[loaded.id] = controller
        return (TerminalRowContextMenu(entry: loaded, model: model), model)
    }

    // MARK: - Enumerated state-set

    func testMenu_inactiveCustom() throws {
        let e = entry(kind: .shell)
        let view = try menu(for: e)
        XCTAssertNil(view.model.activeSession(for: e), "provenance: no live session → Launch")
        XCTAssertTrue(view.model.isCustomSession(e), "provenance: a shell is a custom session")
        XCTAssertFalse(e.isArchived, "provenance: not archived → Archive (not Restore)")
        try assertViewSnapshot(of: view, named: "TerminalRowContextMenu.inactiveCustom")
    }

    func testMenu_archivedCustom() throws {
        let e = entry(kind: .shell, isArchived: true)
        let view = try menu(for: e)
        XCTAssertTrue(view.model.isCustomSession(e), "provenance: still a custom session")
        XCTAssertTrue(view.entry.isArchived, "provenance: archived → Restore arm")
        try assertViewSnapshot(of: view, named: "TerminalRowContextMenu.archivedCustom")
    }

    func testMenu_nonCustom() throws {
        let e = entry(kind: .command)
        let view = try menu(for: e)
        XCTAssertFalse(view.model.isCustomSession(e), "provenance: a command is NOT a custom session")
        try assertViewSnapshot(of: view, named: "TerminalRowContextMenu.nonCustom")
    }

    // MARK: - AN-R2-04 — energy-0 r2 close: the active-session arms (Stop + Restart)

    /// With a LIVE session, two arms fire that every committed fixture (which asserts
    /// `activeSession == nil`) left unexercised — the round-2 mutation sweep proved both
    /// vacuous (mutating "Stop" / "Restart" with no live-session fixture stayed GREEN):
    ///   - the destructive `if model.activeSession(for: entry) != nil` Stop button (`:3624`)
    ///     → `Label("Stop", systemImage: "stop.fill")`
    ///   - the `activeSession == nil ? "Launch" : "Restart"` ternary (`:3619`) → "Restart"
    func testMenu_activeSession_rendersStopAndRestart() throws {
        let (view, model) = try menuWithActiveSession(for: entry(kind: .shell))
        XCTAssertNotNil(model.activeSession(for: view.entry),
                        "provenance: an injected controller → a live session")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="Stop""#), "live session: the Stop button:\n\(tree)")
        XCTAssertTrue(tree.contains(#"image="stop.fill""#), "live session: the stop glyph:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Restart""#), "live session: Launch→Restart:\n\(tree)")
        XCTAssertFalse(tree.contains(#"text="Launch""#), "live session: NOT 'Launch':\n\(tree)")
        try assertViewSnapshot(of: view, named: "TerminalRowContextMenu.activeSession")
    }

    /// Negative control (P2): with NO live session the SAME entry omits the Stop button and
    /// labels the first action "Launch" (not "Restart") — proving the `activeSession`
    /// presence gate is load-bearing for BOTH arms, and the trees differ.
    func testMenu_activeSession_negativeControl_inactiveOmitsStopAndReadsLaunch() throws {
        let (activeView, _) = try menuWithActiveSession(for: entry(kind: .shell))
        let activeTree = try ViewSnapshotHost.snapshotText(of: activeView)

        let inactiveTree = try ViewSnapshotHost.snapshotText(of: try menu(for: entry(kind: .shell)))
        XCTAssertFalse(inactiveTree.contains(#"text="Stop""#), "inactive: no Stop button:\n\(inactiveTree)")
        XCTAssertFalse(inactiveTree.contains(#"image="stop.fill""#), "inactive: no stop glyph:\n\(inactiveTree)")
        XCTAssertTrue(inactiveTree.contains(#"text="Launch""#), "inactive: the Launch label:\n\(inactiveTree)")
        XCTAssertFalse(inactiveTree.contains(#"text="Restart""#), "inactive: NOT 'Restart':\n\(inactiveTree)")

        XCTAssertNotEqual(activeTree, inactiveTree, "the active-session gate must flip the tree")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The custom-session GATE drives the tree: a `.shell` (custom) renders the custom
    /// block (Edit/Duplicate/Delete labels); a `.command` (non-custom) does not. And the
    /// archived flag flips Archive↔Restore. Both are real model-driven branches.
    func testMenu_negativeControl_customGateAndArchiveFlipTree() throws {
        let customTree = try ViewSnapshotHost.snapshotText(of: try menu(for: entry(kind: .shell)))
        let nonCustomTree = try ViewSnapshotHost.snapshotText(of: try menu(for: entry(kind: .command)))
        let archivedTree = try ViewSnapshotHost.snapshotText(of: try menu(for: entry(kind: .shell, isArchived: true)))

        XCTAssertNotEqual(customTree, nonCustomTree, "the isCustomSession gate must drive the tree")
        XCTAssertTrue(customTree.contains("Delete Session"), "custom: the custom block renders:\n\(customTree)")
        XCTAssertFalse(nonCustomTree.contains("Delete Session"), "non-custom: no custom block:\n\(nonCustomTree)")

        XCTAssertNotEqual(customTree, archivedTree, "the archived flag must flip Archive↔Restore")
        XCTAssertTrue(customTree.contains("Archive Session"), "active custom: Archive:\n\(customTree)")
        XCTAssertTrue(archivedTree.contains("Restore"), "archived custom: Restore:\n\(archivedTree)")
    }

    // MARK: - Determinism (P3)

    func testMenu_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, ProcessKind, Bool)] = [
            ("inactiveCustom", .shell, false),
            ("archivedCustom", .shell, true),
            ("nonCustom", .command, false)
        ]
        for (name, kind, archived) in cases {
            let a = try ViewSnapshotHost.snapshotText(of: try menu(for: entry(kind: kind, isArchived: archived)))
            let b = try ViewSnapshotHost.snapshotText(of: try menu(for: entry(kind: kind, isArchived: archived)))
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }
}
#endif
