import XCTest
@testable import OuroWorkbenchCore

/// Slice ②b — the pure Core seam that derives the sidebar/tab-strip view-model from
/// `(workspaces, entries, selectedWorkspaceId)`. Core is test-visible
/// (`@testable import`), so this is real red→green XCTest TDD with 100% line+region.
///
/// The seam owns: workspace row ordering (pinned-first, stable), tab resolution +
/// ordering from `tabIds`, dangling-id drop (attributed), active-workspace selection
/// (DB2), empty-workspace handling (DB5), the attention summary (lean row context),
/// and the active/archived partition (DB7). NO SwiftUI, NO cost/runtime fields.
final class WorkspaceSidebarPresentationTests: XCTestCase {

    // MARK: - Helpers

    private func makeEntry(
        id: UUID = UUID(),
        name: String,
        tabNameOverride: String? = nil,
        attention: AttentionState = .idle,
        isArchived: Bool = false
    ) -> ProcessEntry {
        ProcessEntry(
            id: id,
            projectId: UUID(),
            name: name,
            kind: .terminalAgent,
            executable: "claude",
            workingDirectory: "/tmp/work",
            isArchived: isArchived,
            attention: attention,
            tabNameOverride: tabNameOverride
        )
    }

    private func resolve(
        _ workspaces: [Workspace],
        _ entries: [ProcessEntry],
        selected: UUID? = nil
    ) -> WorkspaceSidebarModel {
        WorkspaceSidebarPresentation.resolve(
            workspaces: workspaces,
            entries: entries,
            selectedWorkspaceId: selected
        )
    }

    // MARK: - Workspace row ordering (pinned-first, stable)

    func testRowsArePinnedFirstThenStoredOrderStable() {
        let a = Workspace(autoName: "A", isPinned: false)
        let b = Workspace(autoName: "B", isPinned: true)
        let c = Workspace(autoName: "C", isPinned: false)
        let d = Workspace(autoName: "D", isPinned: true)
        let model = resolve([a, b, c, d], [])
        // Pinned in their stored order (B, D), then unpinned in stored order (A, C).
        XCTAssertEqual(model.rows.map(\.effectiveName), ["B", "D", "A", "C"])
        XCTAssertEqual(model.rows.map(\.isPinned), [true, true, false, false])
    }

    func testRowsAllUnpinnedPreserveStoredOrder() {
        let a = Workspace(autoName: "A")
        let b = Workspace(autoName: "B")
        let model = resolve([a, b], [])
        XCTAssertEqual(model.rows.map(\.effectiveName), ["A", "B"])
    }

    func testRowsAllPinnedPreserveStoredOrder() {
        let a = Workspace(autoName: "A", isPinned: true)
        let b = Workspace(autoName: "B", isPinned: true)
        let model = resolve([a, b], [])
        XCTAssertEqual(model.rows.map(\.effectiveName), ["A", "B"])
        XCTAssertEqual(model.rows.map(\.isPinned), [true, true])
    }

    func testEmptyWorkspacesListYieldsNoRowsAndNilActive() {
        let model = resolve([], [])
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.activeWorkspaceId)
    }

    func testRowEffectiveNameUsesOverride() {
        let ws = Workspace(autoName: "auto", nameOverride: "Custom")
        let model = resolve([ws], [])
        XCTAssertEqual(model.rows.first?.effectiveName, "Custom")
    }

    // MARK: - Tab resolution + ordering

    func testTabsResolveInTabIdsOrderWithEffectiveTabName() {
        let e1 = makeEntry(name: "first")
        let e2 = makeEntry(name: "auto-2", tabNameOverride: "Renamed")
        let e3 = makeEntry(name: "third")
        // tabIds order is e3, e1, e2 — must be honored, not entry-array order.
        let ws = Workspace(autoName: "W", tabIds: [e3.id, e1.id, e2.id])
        let model = resolve([ws], [e1, e2, e3])
        let row = model.rows.first
        XCTAssertEqual(row?.tabs.map(\.effectiveTabName), ["third", "first", "Renamed"])
        XCTAssertEqual(row?.tabs.map(\.id), [e3.id, e1.id, e2.id])
    }

    func testResolvedTabCarriesAttention() {
        let e1 = makeEntry(name: "a", attention: .blocked)
        let ws = Workspace(autoName: "W", tabIds: [e1.id])
        let model = resolve([ws], [e1])
        XCTAssertEqual(model.rows.first?.tabs.first?.attention, .blocked)
    }

    func testSingleTabWorkspaceResolves() {
        let e1 = makeEntry(name: "solo")
        let ws = Workspace(autoName: "W", tabIds: [e1.id])
        let model = resolve([ws], [e1])
        XCTAssertEqual(model.rows.first?.tabs.count, 1)
        XCTAssertFalse(model.rows.first?.isEmpty ?? true)
    }

    func testManyTabWorkspaceResolves() {
        let entries = (0..<5).map { makeEntry(name: "t\($0)") }
        let ws = Workspace(autoName: "W", tabIds: entries.map(\.id))
        let model = resolve([ws], entries)
        XCTAssertEqual(model.rows.first?.tabs.count, 5)
    }

    // MARK: - Dangling-id drop (DB3 — attributed, not crashed/blank)

    func testDanglingTabIdIsDroppedAndAttributed() {
        let e1 = makeEntry(name: "real")
        let ghost = UUID() // no matching entry
        let ws = Workspace(autoName: "W", tabIds: [e1.id, ghost])
        let model = resolve([ws], [e1])
        let row = model.rows.first
        // Resolved count < tabIds count; the drop is observable.
        XCTAssertEqual(row?.tabs.count, 1)
        XCTAssertEqual(row?.tabs.first?.id, e1.id)
        XCTAssertEqual(row?.droppedTabCount, 1)
    }

    func testAllDanglingTabIdsYieldEmptyRowWithDropCount() {
        let g1 = UUID()
        let g2 = UUID()
        let ws = Workspace(autoName: "W", tabIds: [g1, g2])
        let model = resolve([ws], [])
        let row = model.rows.first
        XCTAssertEqual(row?.tabs.count, 0)
        XCTAssertEqual(row?.archivedTabs.count, 0)
        XCTAssertTrue(row?.isEmpty ?? false)
        XCTAssertEqual(row?.droppedTabCount, 2)
    }

    func testNoDangsYieldZeroDropCount() {
        let e1 = makeEntry(name: "a")
        let ws = Workspace(autoName: "W", tabIds: [e1.id])
        let model = resolve([ws], [e1])
        XCTAssertEqual(model.rows.first?.droppedTabCount, 0)
    }

    func testDuplicateEntryIdsResolveToTheFirstOccurrenceNotCrash() {
        // Defensive: the entry list could (in a corrupt state) carry two rows with
        // the same id. The seam indexes by id keeping the FIRST occurrence, so a tab
        // referencing that id resolves once and deterministically rather than crashing.
        let sharedId = UUID()
        let first = makeEntry(id: sharedId, name: "first-wins")
        let dupe = makeEntry(id: sharedId, name: "should-be-ignored")
        let ws = Workspace(autoName: "W", tabIds: [sharedId])
        let model = resolve([ws], [first, dupe])
        XCTAssertEqual(model.rows.first?.tabs.count, 1)
        XCTAssertEqual(model.rows.first?.tabs.first?.effectiveTabName, "first-wins")
    }

    // MARK: - Active-workspace selection (DB2)

    func testActiveSelectionValidIdPicksThatWorkspace() {
        let a = Workspace(autoName: "A")
        let b = Workspace(autoName: "B")
        let model = resolve([a, b], [], selected: b.id)
        XCTAssertEqual(model.activeWorkspaceId, b.id)
        XCTAssertEqual(model.rows.first { $0.isActive }?.effectiveName, "B")
        // Exactly one row is marked active.
        XCTAssertEqual(model.rows.filter(\.isActive).count, 1)
    }

    func testActiveSelectionNilFallsBackToFirstAfterPinnedFirst() {
        let a = Workspace(autoName: "A", isPinned: false)
        let b = Workspace(autoName: "B", isPinned: true)
        // Pinned-first ordering puts B first → B is the deterministic fallback.
        let model = resolve([a, b], [], selected: nil)
        XCTAssertEqual(model.activeWorkspaceId, b.id)
        XCTAssertEqual(model.rows.first { $0.isActive }?.effectiveName, "B")
    }

    func testActiveSelectionStaleIdFallsBackToFirstAfterPinnedFirst() {
        let a = Workspace(autoName: "A")
        let b = Workspace(autoName: "B")
        let staleId = UUID() // not in the workspace set
        let model = resolve([a, b], [], selected: staleId)
        XCTAssertEqual(model.activeWorkspaceId, a.id) // first after pinned-first (none pinned → stored order)
    }

    func testActiveSelectionNilWithNoPinnedUsesFirstStored() {
        let a = Workspace(autoName: "A")
        let b = Workspace(autoName: "B")
        let model = resolve([a, b], [], selected: nil)
        XCTAssertEqual(model.activeWorkspaceId, a.id)
    }

    // MARK: - Empty-workspace handling (DB5)

    func testEmptyWorkspaceYieldsEmptyMarkerNotHidden() {
        let ws = Workspace(autoName: "Empty", tabIds: [])
        let model = resolve([ws], [])
        XCTAssertEqual(model.rows.count, 1) // not hidden
        let row = model.rows.first
        XCTAssertTrue(row?.isEmpty ?? false)
        XCTAssertEqual(row?.tabs.count, 0)
    }

    func testWorkspaceWithOnlyArchivedTabsIsNotEmpty() {
        // A workspace whose only resolved tabs are archived still has content to
        // show (in the archived list), so it is NOT the empty-state marker.
        let arch = makeEntry(name: "old", isArchived: true)
        let ws = Workspace(autoName: "W", tabIds: [arch.id])
        let model = resolve([ws], [arch])
        let row = model.rows.first
        XCTAssertFalse(row?.isEmpty ?? true)
        XCTAssertEqual(row?.tabs.count, 0)
        XCTAssertEqual(row?.archivedTabs.count, 1)
    }

    // MARK: - Active/archived partition (DB7)

    func testTabsPartitionIntoActiveAndArchivedPreservingOrder() {
        let a1 = makeEntry(name: "active1")
        let arch = makeEntry(name: "archived", isArchived: true)
        let a2 = makeEntry(name: "active2")
        let ws = Workspace(autoName: "W", tabIds: [a1.id, arch.id, a2.id])
        let model = resolve([ws], [a1, arch, a2])
        let row = model.rows.first
        XCTAssertEqual(row?.tabs.map(\.effectiveTabName), ["active1", "active2"])
        XCTAssertEqual(row?.archivedTabs.map(\.effectiveTabName), ["archived"])
        XCTAssertEqual(row?.tabs.allSatisfy { !$0.isArchived }, true)
        XCTAssertEqual(row?.archivedTabs.allSatisfy(\.isArchived), true)
    }

    func testNoArchivedTabsYieldsEmptyArchivedPartition() {
        let a1 = makeEntry(name: "a")
        let ws = Workspace(autoName: "W", tabIds: [a1.id])
        let model = resolve([ws], [a1])
        XCTAssertTrue(model.rows.first?.archivedTabs.isEmpty ?? false)
    }

    func testAllArchivedTabsYieldEmptyActivePartition() {
        let arch1 = makeEntry(name: "a", isArchived: true)
        let arch2 = makeEntry(name: "b", isArchived: true)
        let ws = Workspace(autoName: "W", tabIds: [arch1.id, arch2.id])
        let model = resolve([ws], [arch1, arch2])
        let row = model.rows.first
        XCTAssertTrue(row?.tabs.isEmpty ?? false)
        XCTAssertEqual(row?.archivedTabs.count, 2)
    }

    // MARK: - Attention summary (lean row context) — every AttentionState arm

    func testAttentionSummaryNeedsAttentionWhenAnyActiveTabNeedsHuman() {
        let idle = makeEntry(name: "idle", attention: .idle)
        let waiting = makeEntry(name: "waiting", attention: .waitingOnHuman)
        let ws = Workspace(autoName: "W", tabIds: [idle.id, waiting.id])
        let model = resolve([ws], [idle, waiting])
        let ctx = model.rows.first?.context
        XCTAssertEqual(ctx?.needsAttention, true)
        XCTAssertEqual(ctx?.summary, .waitingOnHuman)
    }

    func testAttentionSummaryHighestSeverityWins() {
        // needsBossReview is the highest-severity arm; it must win over active/idle.
        let active = makeEntry(name: "active", attention: .active)
        let review = makeEntry(name: "review", attention: .needsBossReview)
        let idle = makeEntry(name: "idle", attention: .idle)
        let ws = Workspace(autoName: "W", tabIds: [active.id, review.id, idle.id])
        let model = resolve([ws], [active, review, idle])
        XCTAssertEqual(model.rows.first?.context.summary, .needsBossReview)
        XCTAssertEqual(model.rows.first?.context.needsAttention, true)
    }

    func testAttentionSummaryBlockedBeatsActiveAndIdle() {
        let active = makeEntry(name: "active", attention: .active)
        let blocked = makeEntry(name: "blocked", attention: .blocked)
        let ws = Workspace(autoName: "W", tabIds: [active.id, blocked.id])
        let model = resolve([ws], [active, blocked])
        XCTAssertEqual(model.rows.first?.context.summary, .blocked)
        XCTAssertEqual(model.rows.first?.context.needsAttention, true)
    }

    func testAttentionSummaryActiveBeatsIdleButNotNeedsAttention() {
        let active = makeEntry(name: "active", attention: .active)
        let idle = makeEntry(name: "idle", attention: .idle)
        let ws = Workspace(autoName: "W", tabIds: [idle.id, active.id])
        let model = resolve([ws], [idle, active])
        XCTAssertEqual(model.rows.first?.context.summary, .active)
        XCTAssertEqual(model.rows.first?.context.needsAttention, false)
    }

    func testAttentionSummaryAllIdleIsIdleNoAttention() {
        let i1 = makeEntry(name: "a", attention: .idle)
        let i2 = makeEntry(name: "b", attention: .idle)
        let ws = Workspace(autoName: "W", tabIds: [i1.id, i2.id])
        let model = resolve([ws], [i1, i2])
        XCTAssertEqual(model.rows.first?.context.summary, .idle)
        XCTAssertEqual(model.rows.first?.context.needsAttention, false)
    }

    func testAttentionSummaryWaitingOnHumanArm() {
        let w = makeEntry(name: "w", attention: .waitingOnHuman)
        let ws = Workspace(autoName: "W", tabIds: [w.id])
        let model = resolve([ws], [w])
        XCTAssertEqual(model.rows.first?.context.summary, .waitingOnHuman)
        XCTAssertEqual(model.rows.first?.context.needsAttention, true)
    }

    func testAttentionSummaryIgnoresArchivedTabs() {
        // The summary is over ACTIVE tabs; an archived needsBossReview tab must NOT
        // raise the row's attention.
        let active = makeEntry(name: "a", attention: .idle)
        let archReview = makeEntry(name: "old", attention: .needsBossReview, isArchived: true)
        let ws = Workspace(autoName: "W", tabIds: [active.id, archReview.id])
        let model = resolve([ws], [active, archReview])
        XCTAssertEqual(model.rows.first?.context.summary, .idle)
        XCTAssertEqual(model.rows.first?.context.needsAttention, false)
    }

    func testEmptyWorkspaceHasNilAttentionSummary() {
        let ws = Workspace(autoName: "Empty", tabIds: [])
        let model = resolve([ws], [])
        XCTAssertNil(model.rows.first?.context.summary)
        XCTAssertEqual(model.rows.first?.context.needsAttention, false)
    }

    // MARK: - No-cost / no-runtime boundary invariant (mirrors ②a DA2)

    func testResolvedTabExposesOnlyStructureAndWorkContextNoCostNoRuntime() {
        let e1 = makeEntry(name: "a", attention: .active)
        let ws = Workspace(autoName: "W", tabIds: [e1.id])
        let model = resolve([ws], [e1])
        let tab = try! XCTUnwrap(model.rows.first?.tabs.first)
        let labels = Set(Mirror(reflecting: tab).children.compactMap(\.label))
        XCTAssertEqual(labels, ["id", "effectiveTabName", "attention", "isArchived"])
        let forbidden: Set<String> = [
            "usd", "usdLabel", "tok", "tokens", "cost", "price", "pid", "run",
            "processRun", "status", "startedAt", "transcriptPath", "lastOutputAt",
        ]
        XCTAssertTrue(
            labels.isDisjoint(with: forbidden),
            "ResolvedTab must carry no cost/runtime field; found \(labels.intersection(forbidden))"
        )
    }

    func testWorkspaceRowExposesOnlyStructureNoCostNoRuntime() {
        let e1 = makeEntry(name: "a")
        let ws = Workspace(autoName: "W", tabIds: [e1.id])
        let model = resolve([ws], [e1])
        let row = try! XCTUnwrap(model.rows.first)
        let labels = Set(Mirror(reflecting: row).children.compactMap(\.label))
        let forbidden: Set<String> = [
            "usd", "usdLabel", "tok", "tokens", "cost", "price", "rootPath",
            "pid", "run", "processRun", "status", "startedAt",
        ]
        XCTAssertTrue(
            labels.isDisjoint(with: forbidden),
            "WorkspaceRow must carry no cost/runtime/PWD field; found \(labels.intersection(forbidden))"
        )
    }

    func testRowContextExposesOnlyAttentionSummaryNoCost() {
        let e1 = makeEntry(name: "a", attention: .active)
        let ws = Workspace(autoName: "W", tabIds: [e1.id])
        let model = resolve([ws], [e1])
        let ctx = try! XCTUnwrap(model.rows.first?.context)
        let labels = Set(Mirror(reflecting: ctx).children.compactMap(\.label))
        XCTAssertEqual(labels, ["summary", "needsAttention"])
    }

    // MARK: - Migrated-UI fixture sanity-decode (Unit 0 fixture is valid + decodable)

    func testMigratedUIFixtureDecodesAndResolves() throws {
        let url = repoRoot()
            .appendingPathComponent("worker")
            .appendingPathComponent("tasks")
            .appendingPathComponent("2026-06-24-1946-doing-slice2b-workspaces-sidebar")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("migrated-ui-state.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(WorkspaceState.self, from: Data(contentsOf: url))

        let entries = state.processEntries.filter { $0.kind == .terminalAgent || $0.kind == .shell }
        let model = WorkspaceSidebarPresentation.resolve(
            workspaces: state.workspaces,
            entries: entries,
            selectedWorkspaceId: nil
        )
        // Pinned workspace renders first; "Restored workspace" + "Empty workspace" follow.
        XCTAssertEqual(model.rows.map(\.effectiveName), ["Pinned workspace", "Restored workspace", "Empty workspace"])
        // Active fallback (nil selection) → first pinned → "Pinned workspace".
        XCTAssertEqual(model.rows.first { $0.isActive }?.effectiveName, "Pinned workspace")
        // Restored workspace: 3 active tabs (1 carries the override) + 1 archived.
        let restored = try XCTUnwrap(model.rows.first { $0.effectiveName == "Restored workspace" })
        XCTAssertEqual(restored.tabs.count, 3)
        XCTAssertEqual(restored.archivedTabs.count, 1)
        XCTAssertTrue(restored.tabs.contains { $0.effectiveTabName == "Agent Substrate" })
        XCTAssertEqual(restored.context.needsAttention, true)
        // Empty workspace renders (not hidden) with the empty marker.
        let empty = try XCTUnwrap(model.rows.first { $0.effectiveName == "Empty workspace" })
        XCTAssertTrue(empty.isEmpty)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
