import Foundation

/// Slice ②b — the pure **sidebar / tab-strip view-model derivation seam**.
///
/// Takes the durable workspace structure (`workspaces`), the flat session entries
/// (`entries`, passed in by the App's view-model — the seam stays pure and never
/// reaches into a view-model), and the operator's selected workspace id, and returns
/// the fully ordered + resolved `WorkspaceSidebarModel` the SwiftUI sidebar and the
/// cmux tab-strip render directly. No SwiftUI, no view-model dependency, no I/O.
///
/// It owns every grouping/ordering/display-derivation DECISION (so the views never
/// re-derive and can't disagree with each other):
/// - **Workspace row ordering**: pinned workspaces first (stable), then stored order
///   (mirrors the entry pin rule in `sessionEntries`).
/// - **Tab resolution + ordering**: resolve `tabIds → ProcessEntry` in `tabIds` order,
///   each carrying `effectiveTabName`; a `tabId` with no matching entry is DROPPED
///   (never crashed, never blank) and the drop is ATTRIBUTED via `droppedTabCount`
///   (DB3) so it's never silently wrong.
/// - **Active-workspace selection** (DB2): `selectedWorkspaceId` valid → that workspace;
///   nil OR stale → the FIRST workspace after pinned-first ordering. Deterministic so a
///   just-migrated single-"Restored workspace" state has a defined active workspace.
/// - **Empty-workspace handling** (DB5): a workspace with zero resolved tabs (active OR
///   archived) yields `isEmpty == true` so the view shows "no tabs yet", never blank.
/// - **Active/archived partition** (DB7): a workspace's resolved tabs split into `tabs`
///   (active → the strip) vs `archivedTabs` (the per-workspace Archived list).
/// - **Attention summary** (lean row context): the highest-severity `AttentionState`
///   among the workspace's ACTIVE tabs, plus a `needsAttention` flag.
///
/// **PERSISTENCE/COST BOUNDARY (mirrors ②a DA2):** the returned model + `ResolvedTab`
/// + `WorkspaceRowContext` carry ONLY structure + work-context (name, tabs, attention,
/// pin, empty marker). NEVER cost (`usd`/`tok`/`price`) and NEVER live runtime
/// (`pid`/`run`/`status`/`startedAt`). Branch/diffstat live App-side via
/// `model.gitStatus(for:)` and are passed through the view, never recomputed here. A
/// unit-tested `Mirror` invariant pins this surface.
public enum WorkspaceSidebarPresentation {

    /// One resolved tab in a workspace — the operator-visible tab name, its attention
    /// (work-context, drives the row glyph), and whether it's archived. NO cost/runtime.
    public struct ResolvedTab: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let effectiveTabName: String
        public let attention: AttentionState
        public let isArchived: Bool

        public init(id: UUID, effectiveTabName: String, attention: AttentionState, isArchived: Bool) {
            self.id = id
            self.effectiveTabName = effectiveTabName
            self.attention = attention
            self.isArchived = isArchived
        }
    }

    /// Lean row work-context: the attention summary for a workspace's ACTIVE tabs.
    /// `summary` is the highest-severity attention present (nil when there are no
    /// active tabs); `needsAttention` is true iff any active tab is asking for the
    /// operator. NO cost field.
    public struct WorkspaceRowContext: Equatable, Sendable {
        public let summary: AttentionState?
        public let needsAttention: Bool

        public init(summary: AttentionState?, needsAttention: Bool) {
            self.summary = summary
            self.needsAttention = needsAttention
        }
    }

    /// One resolved workspace row: identity, display name, pin/active flags, the
    /// active-vs-archived tab partition, the attention summary, the dangling-id drop
    /// count, and the empty marker. NO cost/runtime/PWD field.
    public struct WorkspaceRow: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let effectiveName: String
        public let isPinned: Bool
        public let isActive: Bool
        public let tabs: [ResolvedTab]
        public let archivedTabs: [ResolvedTab]
        public let droppedTabCount: Int
        public let context: WorkspaceRowContext

        /// True iff the workspace resolved to zero tabs (active AND archived) — the
        /// view shows the "no tabs yet" empty state rather than blank pixels (DB5).
        public var isEmpty: Bool { tabs.isEmpty && archivedTabs.isEmpty }

        public init(
            id: UUID,
            effectiveName: String,
            isPinned: Bool,
            isActive: Bool,
            tabs: [ResolvedTab],
            archivedTabs: [ResolvedTab],
            droppedTabCount: Int,
            context: WorkspaceRowContext
        ) {
            self.id = id
            self.effectiveName = effectiveName
            self.isPinned = isPinned
            self.isActive = isActive
            self.tabs = tabs
            self.archivedTabs = archivedTabs
            self.droppedTabCount = droppedTabCount
            self.context = context
        }
    }

    /// The whole sidebar/tab-strip view-model: the ordered rows and the resolved
    /// active-workspace id (nil only when there are no workspaces).
    public struct WorkspaceSidebarModel: Equatable, Sendable {
        public let rows: [WorkspaceRow]
        public let activeWorkspaceId: UUID?

        public init(rows: [WorkspaceRow], activeWorkspaceId: UUID?) {
            self.rows = rows
            self.activeWorkspaceId = activeWorkspaceId
        }
    }

    /// Derive the sidebar/tab-strip view-model. Pure — same inputs always give the
    /// same output. See the type doc for the ordering/resolution/selection rules.
    public static func resolve(
        workspaces: [Workspace],
        entries: [ProcessEntry],
        selectedWorkspaceId: UUID?
    ) -> WorkspaceSidebarModel {
        // Pinned-first, stable: pinned in stored order, then unpinned in stored order.
        // Concatenation (not `sorted`) keeps each partition's stored order stable.
        let ordered = workspaces.filter(\.isPinned) + workspaces.filter { !$0.isPinned }

        // Active-workspace selection (DB2): a valid selection wins; nil/stale falls
        // back to the first workspace AFTER pinned-first ordering (so a pinned
        // workspace is the default). nil only when there are no workspaces.
        let activeId: UUID?
        if let selectedWorkspaceId, ordered.contains(where: { $0.id == selectedWorkspaceId }) {
            activeId = selectedWorkspaceId
        } else {
            activeId = ordered.first?.id
        }

        // Index entries by id once so per-tab resolution is O(1).
        let entryById = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let rows = ordered.map { workspace -> WorkspaceRow in
            var active: [ResolvedTab] = []
            var archived: [ResolvedTab] = []
            var dropped = 0
            for tabId in workspace.tabIds {
                guard let entry = entryById[tabId] else {
                    // Dangling id — the entry was deleted. Drop it (never crash/blank)
                    // and attribute the drop (DB3).
                    dropped += 1
                    continue
                }
                let tab = ResolvedTab(
                    id: entry.id,
                    effectiveTabName: entry.effectiveTabName,
                    attention: entry.attention,
                    isArchived: entry.isArchived
                )
                if entry.isArchived {
                    archived.append(tab)
                } else {
                    active.append(tab)
                }
            }
            return WorkspaceRow(
                id: workspace.id,
                effectiveName: workspace.effectiveName,
                isPinned: workspace.isPinned,
                isActive: workspace.id == activeId,
                tabs: active,
                archivedTabs: archived,
                droppedTabCount: dropped,
                context: rowContext(activeTabs: active)
            )
        }

        return WorkspaceSidebarModel(rows: rows, activeWorkspaceId: activeId)
    }

    /// The lean row attention summary over a workspace's ACTIVE tabs: the
    /// highest-severity attention present, plus whether any active tab needs the
    /// operator. Archived tabs are excluded by construction (the caller passes only
    /// the active partition). No active tabs → nil summary, no attention.
    private static func rowContext(activeTabs: [ResolvedTab]) -> WorkspaceRowContext {
        guard let summary = activeTabs.map(\.attention).max(by: { severity($0) < severity($1) }) else {
            return WorkspaceRowContext(summary: nil, needsAttention: false)
        }
        let needsAttention = activeTabs.contains { $0.attention.needsHuman }
        return WorkspaceRowContext(summary: summary, needsAttention: needsAttention)
    }

    /// Total order over `AttentionState` for "which state the row's summary surfaces"
    /// — higher wins. `needsBossReview` is the most urgent (a boss-raised review),
    /// then the operator-blocking states, then `active`, then `idle`. Pins the
    /// highest-severity-wins rule so every arm is deterministic.
    private static func severity(_ state: AttentionState) -> Int {
        switch state {
        case .idle: return 0
        case .active: return 1
        case .waitingOnHuman: return 2
        case .blocked: return 3
        case .needsBossReview: return 4
        }
    }
}

// Re-export the nested types at module scope so callers (tests + App) reference
// `WorkspaceSidebarModel` / `WorkspaceRow` / `ResolvedTab` / `WorkspaceRowContext`
// without the enum prefix, matching the seam's documented public surface.
public typealias WorkspaceSidebarModel = WorkspaceSidebarPresentation.WorkspaceSidebarModel
public typealias WorkspaceRow = WorkspaceSidebarPresentation.WorkspaceRow
public typealias ResolvedTab = WorkspaceSidebarPresentation.ResolvedTab
public typealias WorkspaceRowContext = WorkspaceSidebarPresentation.WorkspaceRowContext
