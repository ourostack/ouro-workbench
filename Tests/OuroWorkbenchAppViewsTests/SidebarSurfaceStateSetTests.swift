#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// SU3 — Surface A (sidebar) COMPLETE enumerated state-set on `WorkbenchSidebarView`
/// (campaign §Surfaces A): empty / one / many; pinned-first ordering; active-vs-
/// inactive; empty-workspace marker (`SidebarWorkspaceEmptyRow`); summary idle-vs-
/// needs-you (health glyph + "needs you" a11y); rename-in-progress (`InlineRenameEditor`
/// swapped in); boundary pinned+active; custom name-override (`WorkspaceRow.nameOverride`).
///
/// **C1 — the sidebar SURFACE is CLOCK-FREE.** Through the real seam,
/// `TerminalAgentRow` is constructed in exactly one place (the Archived section)
/// WITHOUT `runningSince:`, so `ElapsedTimePill` is never rendered and no elapsed /
/// `Date()` substring can appear in a sidebar reference. The elapsed seam is
/// exercised on the standalone leaf in `TerminalAgentRowRunningLeafTests` (SU3r),
/// NOT here. `testSidebar_isClockFree_noElapsedSubstring` is a defense-in-depth
/// assertion of that invariant.
///
/// Every fixture is provenance-built via the REAL seam:
/// `WorkbenchStore(paths:).save(state)` → a fresh `WorkbenchViewModel(paths:…)` whose
/// `load()` reads + migrates the persisted `WorkspaceState`, deriving
/// `workspaceSidebarModel.rows` through the pure `WorkspaceSidebarPresentation.resolve`
/// seam — NEVER hand-assembled (P2). Each VM injects a temp `agentBundlesURL` so no
/// test touches the real `~/AgentBundles` (AN-001). The host pins the locale to
/// `en_US_POSIX` and the serializer whitelist makes a machine-path / clock / UUID
/// leak structurally impossible (P3).
///
/// **Provenance-preservation facts (verified against the load path):**
///   - `load()` runs `bootstrappedState` → `removeUntouchedBootstrapScaffolds`, which
///     drops ONLY preset/"Demo Agent" `.terminalAgent` scaffolds. Fixtures use `.shell`
///     entries with distinctive names → never removed.
///   - `load()` runs `migrateToWorkspaceStructure()`, which APPENDS any non-archived
///     entry not already in a workspace's `tabIds` to a "Restored workspace". Fixtures
///     reference EVERY non-archived entry from a workspace's `tabIds` → migration is a
///     no-op, so the saved structure survives intact.
///   - `reconcile()` re-derives `attention` ONLY for entries with a needs-recovery
///     `ProcessRun`. Fixtures carry NO `processRuns` → the explicit `attention` survives.
///
/// **Coverage mapping (minimal, non-redundant — P4c/P4e):**
///   - `A.empty`              — no agents, no workspaces → only the action rows.
///   - `A.one`                — one workspace, one tab, idle (no health glyph).
///   - `A.many.pinnedFirst`   — three workspaces: an unpinned-active, an unpinned, and
///                              a pinned → pinned sorts FIRST; the BOUNDARY pinned+active
///                              row (selected) renders pin glyph + semibold + active a11y;
///                              an inactive row renders the inactive glyph.
///   - `A.emptyWorkspace`     — a workspace with zero tabs → its row + the
///                              `SidebarWorkspaceEmptyRow` "No tabs yet" marker.
///   - `A.needsYou`           — a workspace whose active tab is `.waitingOnHuman` →
///                              the health glyph + ", needs you" a11y (vs idle: none).
///   - `A.renameInProgress`   — a workspace row in rename mode → `InlineRenameEditor`
///                              swapped in (TextField "Name" + the caption), no row button.
///   - `A.customOverride`     — a workspace with a `nameOverride` → `effectiveName`
///                              shows the override (the override-vs-auto driver, L2:
///                              asserted via row STATE, not the context menu).
@MainActor
final class SidebarSurfaceStateSetTests: XCTestCase {

    // MARK: - Hermetic provenance fixture (AN-001-safe)

    /// Persist `state` via the real store, then build a fresh VM that loads it. The
    /// VM's `load()` reads + bootstraps + migrates + reconciles the saved
    /// `WorkspaceState`, deriving the sidebar rows through the pure seam.
    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("su3-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        let model = WorkbenchViewModel(
            paths: paths,
            // AN-001 — redirect BOTH the registrar cleanup AND the agent inventory
            // scan at the temp `AgentBundles` (a non-existent dir → `scan()` returns
            // []). Without the inventory injection `refreshOuroAgents()` would scan
            // the REAL `~/AgentBundles` and leak machine-local agent names into the
            // sidebar tree (a P3 determinism violation — the sidebar renders
            // `model.ouroAgents`, unlike the ④ card which does not).
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
        return model
    }

    private func sidebar(_ model: WorkbenchViewModel) -> WorkbenchSidebarView {
        WorkbenchSidebarView(model: model)
    }

    /// A `.shell` session entry (a tab) with a distinctive name (so the bootstrap
    /// scaffold-removal never matches it) and an explicit `attention` (which survives
    /// load because no `ProcessRun` references it). A fixed `projectId` keeps it
    /// hermetic; ids never appear in the serialized tree.
    private func tab(
        id: UUID,
        name: String,
        attention: AttentionState = .idle,
        tabNameOverride: String? = nil,
        isArchived: Bool = false
    ) -> ProcessEntry {
        ProcessEntry(
            id: id,
            projectId: Self.projectId,
            name: name,
            kind: .shell,
            executable: "/bin/zsh",
            workingDirectory: "/tmp/su3",
            isArchived: isArchived,
            attention: attention,
            tabNameOverride: tabNameOverride
        )
    }

    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!

    /// Build a `WorkspaceState` from explicit workspaces + their tab entries. Every
    /// non-archived entry MUST be referenced by some workspace's `tabIds` (asserted by
    /// the migration no-op invariant); `processRuns` is empty so attention survives.
    private func state(workspaces: [Workspace], entries: [ProcessEntry]) -> WorkspaceState {
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            processEntries: entries,
            workspaces: workspaces
        )
    }

    // Fixed workspace ids — stable input order → stable resolved row order.
    private static let wsA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private static let wsB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    private static let wsC = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!
    private static let tab1 = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
    private static let tab2 = UUID(uuidString: "22222222-0000-0000-0000-000000000002")!
    private static let tab3 = UUID(uuidString: "33333333-0000-0000-0000-000000000003")!

    // MARK: - empty / one / many

    func testA_empty() throws {
        // No agents (hermetic temp bundles → empty `ouroAgents`), no workspaces →
        // only the always-present action rows ("Create Your First Agent", "New Terminal").
        let model = try makeVM(state: state(workspaces: [], entries: []))
        XCTAssertTrue(model.workspaceSidebarModel.rows.isEmpty, "provenance: no workspace rows")
        try assertViewSnapshot(of: sidebar(model), named: "A.empty")
    }

    func testA_one() throws {
        // One workspace with one idle tab → a single lean row (no health glyph) + its tab.
        let entries = [tab(id: Self.tab1, name: "build")]
        let workspaces = [Workspace(id: Self.wsA, autoName: "Frontend", tabIds: [Self.tab1])]
        let model = try makeVM(state: state(workspaces: workspaces, entries: entries))
        XCTAssertEqual(model.workspaceSidebarModel.rows.count, 1, "provenance: exactly one row")
        try assertViewSnapshot(of: sidebar(model), named: "A.one")
    }

    func testA_many_pinnedFirst() throws {
        // Stored order: [Alpha (unpinned), Bravo (unpinned), Charlie (PINNED)].
        // The seam sorts pinned-first → Charlie sorts ABOVE Alpha/Bravo. With
        // selectedWorkspaceID nil, the FIRST resolved row (Charlie, pinned) is active —
        // the BOUNDARY pinned+active row. Alpha/Bravo render inactive.
        let entries = [
            tab(id: Self.tab1, name: "alpha-tab"),
            tab(id: Self.tab2, name: "bravo-tab"),
            tab(id: Self.tab3, name: "charlie-tab")
        ]
        let workspaces = [
            Workspace(id: Self.wsA, autoName: "Alpha", isPinned: false, tabIds: [Self.tab1]),
            Workspace(id: Self.wsB, autoName: "Bravo", isPinned: false, tabIds: [Self.tab2]),
            Workspace(id: Self.wsC, autoName: "Charlie", isPinned: true, tabIds: [Self.tab3])
        ]
        let model = try makeVM(state: state(workspaces: workspaces, entries: entries))
        let rows = model.workspaceSidebarModel.rows
        XCTAssertEqual(rows.map(\.effectiveName), ["Charlie", "Alpha", "Bravo"],
                       "provenance: pinned (Charlie) sorts first")
        XCTAssertTrue(rows.first?.isActive == true && rows.first?.isPinned == true,
                      "provenance: the first row is the pinned+active boundary")
        try assertViewSnapshot(of: sidebar(model), named: "A.many.pinnedFirst")
    }

    // MARK: - empty-workspace marker

    func testA_emptyWorkspace() throws {
        // A workspace with zero tabs → its row renders + the inline "No tabs yet" marker
        // (`SidebarWorkspaceEmptyRow`). No stray entries (migration no-op).
        let workspaces = [Workspace(id: Self.wsA, autoName: "Scratch", tabIds: [])]
        let model = try makeVM(state: state(workspaces: workspaces, entries: []))
        XCTAssertTrue(model.workspaceSidebarModel.rows.first?.isEmpty == true,
                      "provenance: the workspace resolved empty")
        try assertViewSnapshot(of: sidebar(model), named: "A.emptyWorkspace")
    }

    // MARK: - summary idle vs needs-you

    func testA_needsYou() throws {
        // The workspace's active tab is `.waitingOnHuman` → the row's `context.summary`
        // is non-idle (health glyph renders) AND `needsAttention` is true (", needs you"
        // a11y). Contrast with the idle `A.one` (no glyph, no "needs you").
        let entries = [tab(id: Self.tab1, name: "waiting-tab", attention: .waitingOnHuman)]
        let workspaces = [Workspace(id: Self.wsA, autoName: "Review", tabIds: [Self.tab1])]
        let model = try makeVM(state: state(workspaces: workspaces, entries: entries))
        let row = try XCTUnwrap(model.workspaceSidebarModel.rows.first)
        XCTAssertEqual(row.context.summary, .waitingOnHuman, "provenance: non-idle summary")
        XCTAssertTrue(row.context.needsAttention, "provenance: needs the operator")
        try assertViewSnapshot(of: sidebar(model), named: "A.needsYou")
    }

    // MARK: - rename-in-progress

    func testA_renameInProgress() throws {
        // Put the workspace row into rename mode → `WorkspaceSidebarRow` swaps the row
        // button for `InlineRenameEditor` (a "Name" TextField + the caption). The
        // begin-rename call is the real model seam (the same one ⇧⌘R drives).
        let entries = [tab(id: Self.tab1, name: "rename-tab")]
        let workspaces = [Workspace(id: Self.wsA, autoName: "Renaming", tabIds: [Self.tab1])]
        let model = try makeVM(state: state(workspaces: workspaces, entries: entries))
        model.beginRename(.workspace(Self.wsA), prefill: "Renaming")
        XCTAssertTrue(model.inlineRename.isEditing(.workspace(Self.wsA)),
                      "provenance: the row is in rename mode")
        try assertViewSnapshot(of: sidebar(model), named: "A.renameInProgress")
    }

    // MARK: - custom name-override (boundary)

    func testA_customOverride() throws {
        // A workspace whose `nameOverride` is set → `effectiveName` shows the override
        // (not the autoName). L2: asserted via the row STATE (`nameOverride`), not the
        // context menu (which is NOT in the ViewInspector tree).
        let entries = [tab(id: Self.tab1, name: "override-tab")]
        let workspaces = [
            Workspace(id: Self.wsA, autoName: "auto-name", nameOverride: "Custom Name", tabIds: [Self.tab1])
        ]
        let model = try makeVM(state: state(workspaces: workspaces, entries: entries))
        let row = try XCTUnwrap(model.workspaceSidebarModel.rows.first)
        XCTAssertEqual(row.nameOverride, "Custom Name", "provenance: override present")
        XCTAssertEqual(row.effectiveName, "Custom Name", "provenance: override wins over autoName")
        try assertViewSnapshot(of: sidebar(model), named: "A.customOverride")
    }

    // MARK: - Negative control (P2)

    /// NEGATIVE CONTROL — mutating the saved `WorkspaceState` flips the sidebar tree:
    /// (a) renaming a workspace changes `effectiveName`; (b) toggling a tab's attention
    /// from idle → waitingOnHuman adds the health glyph; (c) clearing a name override
    /// reverts `effectiveName` to the autoName.
    func testA_negativeControl_workspaceMutationsFlipTree() throws {
        func tree(name: String, attention: AttentionState, override: String?) throws -> String {
            let entries = [tab(id: Self.tab1, name: "nc-tab", attention: attention)]
            let workspaces = [Workspace(id: Self.wsA, autoName: name, nameOverride: override, tabIds: [Self.tab1])]
            return try ViewSnapshotHost.snapshotText(of: self.sidebar(try self.makeVM(
                state: self.state(workspaces: workspaces, entries: entries))))
        }
        let base = try tree(name: "Original", attention: .idle, override: nil)
        let renamed = try tree(name: "Renamed", attention: .idle, override: nil)
        let needsYou = try tree(name: "Original", attention: .waitingOnHuman, override: nil)
        let overridden = try tree(name: "Original", attention: .idle, override: "Override")

        XCTAssertNotEqual(base, renamed, "renaming a workspace must change the tree")
        XCTAssertTrue(base.contains(#"text="Original""#), base)
        XCTAssertTrue(renamed.contains(#"text="Renamed""#), renamed)

        XCTAssertNotEqual(base, needsYou, "an active tab needing the operator must change the tree")
        XCTAssertFalse(base.contains("hand.raised.fill"), "idle: no waiting glyph:\n\(base)")
        XCTAssertTrue(needsYou.contains("hand.raised.fill"), "waitingOnHuman: glyph present:\n\(needsYou)")
        XCTAssertTrue(needsYou.contains("needs you"), "waitingOnHuman: 'needs you' a11y:\n\(needsYou)")

        XCTAssertNotEqual(base, overridden, "setting a name override must change the tree")
        XCTAssertTrue(overridden.contains(#"text="Override""#), overridden)
    }

    // MARK: - Determinism + the clock-free invariant (P3 / C1)

    func testA_determinism_eachFixtureByteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, () throws -> String)] = [
            ("empty", { try ViewSnapshotHost.snapshotText(of: self.sidebar(try self.makeVM(
                state: self.state(workspaces: [], entries: [])))) }),
            ("one", {
                try ViewSnapshotHost.snapshotText(of: self.sidebar(try self.makeVM(state: self.state(
                    workspaces: [Workspace(id: Self.wsA, autoName: "Frontend", tabIds: [Self.tab1])],
                    entries: [self.tab(id: Self.tab1, name: "build")]))))
            }),
            ("many", {
                try ViewSnapshotHost.snapshotText(of: self.sidebar(try self.makeVM(state: self.state(
                    workspaces: [
                        Workspace(id: Self.wsA, autoName: "Alpha", isPinned: false, tabIds: [Self.tab1]),
                        Workspace(id: Self.wsC, autoName: "Charlie", isPinned: true, tabIds: [Self.tab3])
                    ],
                    entries: [self.tab(id: Self.tab1, name: "alpha-tab"), self.tab(id: Self.tab3, name: "charlie-tab")]))))
            })
        ]
        for (name, make) in cases {
            let a = try make()
            let b = try make()
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }

    /// C1 — the sidebar SURFACE is CLOCK-FREE. Even with a running-looking session
    /// (an active tab + a recent `ProcessRun`), the sidebar never constructs
    /// `TerminalAgentRow` with `runningSince:`, so NO elapsed pill / `Date()` substring
    /// appears. We assert the rendered tree carries no elapsed-shaped token (the
    /// `WorkbenchElapsedFormatter` coarse vocabulary: "now"/"Ns"/"Nm"/"Nh"/"Nd",
    /// "running for …"). The elapsed seam lives on the SU3r leaf, not here.
    func testSidebar_isClockFree_noElapsedSubstring() throws {
        let entries = [tab(id: Self.tab1, name: "active-tab", attention: .active)]
        let workspaces = [Workspace(id: Self.wsA, autoName: "Live", tabIds: [Self.tab1])]
        let tree = try ViewSnapshotHost.snapshotText(of: sidebar(try makeVM(
            state: state(workspaces: workspaces, entries: entries))))
        XCTAssertFalse(tree.contains("running for "),
                       "the sidebar surface must render no elapsed accessibility read:\n\(tree)")
        for token in ["1m", "2m", "5m", "1h", "2h", "1d"] {
            XCTAssertFalse(tree.contains(#"text="\#(token)""#),
                           "the sidebar surface must render no elapsed pill (\(token)):\n\(tree)")
        }
    }
}
#endif
