import XCTest
@testable import OuroWorkbenchCore

/// Slice ②b — FIX PASS (FP1/FP2/FP3).
///
/// The independent review BLOCKED merge on a CRITICAL: after ②a's REAL migration,
/// archived terminals become invisible + un-restorable. The cause is structural —
/// `migrateToWorkspaceStructure()` folds ONLY non-archived entries into the
/// "Restored workspace", so archived entries are in NO workspace's `tabIds`. Any
/// Archived section scoped to a workspace's `tabIds` therefore orphans them after
/// upgrade.
///
/// DB10 (supersedes DB7): the Archived section is GLOBAL — derived from
/// `processEntries` filtered to archived terminal/shell sessions, decoupled from
/// workspace membership. These tests pin that global resolver AND prove archived
/// entries survive the REAL migration (no hand-built `tabIds`).
final class WorkspaceGlobalArchivedTests: XCTestCase {

    private func makeEntry(
        id: UUID = UUID(),
        name: String,
        kind: ProcessKind = .terminalAgent,
        tabNameOverride: String? = nil,
        attention: AttentionState = .idle,
        isArchived: Bool = false
    ) -> ProcessEntry {
        ProcessEntry(
            id: id,
            projectId: UUID(),
            name: name,
            kind: kind,
            executable: "claude",
            workingDirectory: "/tmp/work",
            isArchived: isArchived,
            attention: attention,
            tabNameOverride: tabNameOverride
        )
    }

    // MARK: - Global archived resolver (DB10)

    func testGlobalArchivedResolvesOnlyArchivedTerminalAndShellEntries() {
        let activeTerm = makeEntry(name: "active term", isArchived: false)
        let archivedTerm = makeEntry(name: "archived term", isArchived: true)
        let archivedShell = makeEntry(name: "archived shell", kind: .shell, isArchived: true)
        let archivedCommand = makeEntry(name: "archived cmd", kind: .command, isArchived: true)
        let archivedBoss = makeEntry(name: "archived boss", kind: .ouroBoss, isArchived: true)

        let resolved = WorkspaceSidebarPresentation.resolveGlobalArchived(
            entries: [activeTerm, archivedTerm, archivedShell, archivedCommand, archivedBoss]
        )

        // Only archived terminal + shell sessions surface; active ones and
        // non-session kinds (command/boss) are excluded.
        XCTAssertEqual(resolved.map(\.effectiveTabName), ["archived term", "archived shell"])
        XCTAssertTrue(resolved.allSatisfy(\.isArchived))
    }

    func testGlobalArchivedPreservesEntryOrderAndSurfacesEffectiveTabName() {
        let a = makeEntry(name: "a (auto)", tabNameOverride: "Override A", isArchived: true)
        let b = makeEntry(name: "b", isArchived: true)
        let resolved = WorkspaceSidebarPresentation.resolveGlobalArchived(entries: [a, b])
        // Order preserved; the override surfaces via effectiveTabName.
        XCTAssertEqual(resolved.map(\.effectiveTabName), ["Override A", "b"])
    }

    func testGlobalArchivedIsEmptyWhenNothingArchived() {
        let a = makeEntry(name: "a", isArchived: false)
        XCTAssertTrue(WorkspaceSidebarPresentation.resolveGlobalArchived(entries: [a]).isEmpty)
        XCTAssertTrue(WorkspaceSidebarPresentation.resolveGlobalArchived(entries: []).isEmpty)
    }

    // MARK: - CRITICAL regression: archived entries survive the REAL migration

    func testArchivedEntriesAreGloballyVisibleAfterRealMigration() {
        // Drive the REAL migration — no hand-built tabIds. Two active + one archived.
        let active1 = makeEntry(name: "active1", isArchived: false)
        let active2 = makeEntry(name: "active2", isArchived: false)
        let archived = makeEntry(name: "archived run", isArchived: true)

        var state = WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            processEntries: [active1, active2, archived]
        )
        state.migrateToWorkspaceStructure()

        // The migration folded ONLY the active entries into the Restored workspace —
        // the archived id is in NO workspace's tabIds (the structural cause of FP1).
        let restored = state.workspaces.first { $0.autoName == WorkspaceState.migratedWorkspaceSeedName }
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.tabIds.sorted(by: { $0.uuidString < $1.uuidString }),
                       [active1.id, active2.id].sorted(by: { $0.uuidString < $1.uuidString }))
        XCTAssertFalse(restored?.tabIds.contains(archived.id) ?? true,
                       "the archived id must NOT be in any workspace's tabIds (real migration)")

        // The per-workspace seam partition can therefore NEVER surface it...
        let model = WorkspaceSidebarPresentation.resolve(
            workspaces: state.workspaces, entries: state.processEntries, selectedWorkspaceId: nil
        )
        XCTAssertTrue(model.rows.allSatisfy { $0.archivedTabs.isEmpty },
                      "post-migration, no workspace's archivedTabs partition contains the archived entry")

        // ...but the GLOBAL resolver STILL surfaces it (DB10 — no orphaning).
        let globallyArchived = WorkspaceSidebarPresentation.resolveGlobalArchived(
            entries: state.processEntries
        )
        XCTAssertEqual(globallyArchived.map(\.effectiveTabName), ["archived run"])
        XCTAssertEqual(globallyArchived.map(\.id), [archived.id])
    }
}
