#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C2-7 — `BossDashboardView` (the high-fan-out boss pane, #U21-#U23c). The calm,
/// terminal-first boss surface whose `scrollBody` is a deep stack of data-driven gates:
///   - `if let door = model.inboxDoor` → the `InboxDoorPill`.
///   - `if bossWatchLastError != nil, consecutiveFailures >= 2` → the persistent
///       boss-down banner (copy from the pure `BossCheckInFailureCopy` seam — the raw
///       error is NEVER interpolated, so it's leak-free + deterministic).
///   - `if bossCheckInIsRunning` → the "Asking <boss>…" spinner row.
///   - `if let dashboard` → `DashboardMetricsStrip`.
///   - `if let visibility` → `WorkbenchVisibilityStrip`.
///   - `if let dashboard, !availability.issues.isEmpty` → `MailboxWarningView`.
///   - `if let answer = model.bossCheckInAnswer` → the "Boss Reply" block.
///   - `if let dashboard` → `BossNeedsMeCodingColumns` + `HabitHistoryPanelView`.
///   - the "Show/Hide Advanced" button (label reflects `showsAdvanced`).
/// Each gate flips whole CAPTURED subtrees → the genuine high-fan-out state-set.
///
/// **Provenance (P2).** Every state is built through the REAL model seam:
///   - `inboxDoor` is DERIVED (`InboxDoorPresentation.resolve`) from a real `decisionLog`
///       seeded via the production `state.recordDecision`.
///   - `bossDashboard` is provenance-built through the REAL `BossDashboardBuilder().build`
///       from real mailbox views (the exact builder `refreshBossDashboard` calls).
///   - `bossWatchLastError` / `bossWatchConsecutiveFailures` / `bossCheckInIsRunning` /
///       `bossCheckInAnswer` are the SAME writable `@Published` the live boss-watch loop +
///       check-in flow set — direct injection IS the production seam (the AN-001 precedent).
///   - `model` is built via the `makeVM` dual-injection store seam (AN-001 hermetic —
///       no `~/AgentBundles` scan leaks a machine agent name).
///
/// **Determinism (P3).** A single fixed epoch for the seeded decision; a fixed boss name
/// ("boss"); the boss-down banner copy is seam-derived (no raw error); the dashboard
/// fixtures carry fixed strings + a `/tmp/u4` workdir (no `/Users/`). The `.help(...)`
/// tooltips are dropped by the host (AN-004). Byte-identical twice + `!contains("/Users/")`.
///
/// **The `showsAdvanced == true` arm — CLASSIFIED UNREACHABLE + ALLOWLIST CARVE (not
/// fabricated; the C9 live-arm discipline):** `showsAdvanced` is `@State private = false`
/// with NO init seam, so the synchronous `inspect()` always renders the INITIAL state
/// (`false`) — the expanded arm is structurally unreachable through the snapshot seam.
/// AND that arm embeds `MachineRuntimeView`, whose `@StateObject LoginItemController` is
/// non-injectable (allowlist-candidate #2). We therefore enumerate the REACHABLE
/// (collapsed) arm fully and record the expanded arm as a verified carve-out (see
/// `allowlist-candidates.md`), NEVER fabricating an unreachable state. The collapsed-arm
/// snapshots assert the "Show Advanced" button label, which PROVES `showsAdvanced == false`.
///
/// **Enumerated state-set (the reachable collapsed arm):**
///   - `empty`         — no door / error / dashboard / answer → only the boss conversation
///       + the "Show Advanced" button (the calm/absent baseline).
///   - `doorOnly`      — an open inbox → the `InboxDoorPill` renders above the conversation.
///   - `watchError`    — boss-down (error + ≥2 failures) → the persistent banner.
///   - `checkInRunning`— a live check-in → the "Asking boss…" spinner row.
///   - `fullDashboard` — door + watch error + check-in + dashboard (with issues) + answer +
///       needs-me/coding/habits → every gate firing at once (the densest real pane).
@MainActor
final class BossDashboardViewStateSetTests: XCTestCase {

    private static let fixedNow = Date(timeIntervalSince1970: 1_767_323_045)

    // MARK: - Hermetic model (AN-001 dual-injection) + real seam population

    private func makeVM(seedDecision: Bool) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c2-bossdash-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        var state = WorkspaceState(boss: BossAgentSelection(agentName: "boss"))
        if seedDecision {
            state.recordDecision(BossInboxDecision(
                occurredAt: Self.fixedNow, source: "boss:fixture",
                prompt: "Approve the migration plan?", kind: .escalate, reasoning: "fixture"))
        }
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    /// A real dashboard through the REAL builder (with a probe issue so MailboxWarningView fires).
    private func dashboard() -> BossDashboardSnapshot {
        BossDashboardBuilder().build(
            boss: BossAgentSelection(agentName: "boss"),
            machine: nil,
            needsMe: MailboxNeedsMeView(items: [
                MailboxNeedsMeItem(urgency: "u", label: "Review the rename", detail: "decision ready",
                                   ref: MailboxNavigationRef(tab: "sessions", focus: "sess-1"), ageMs: 100)
            ]),
            coding: MailboxCodingSummary(totalCount: 1, activeCount: 1, blockedCount: 0, items: [
                MailboxCodingItem(id: "c1", runner: "codex", status: "running", workdir: "/tmp/u4-repo",
                                  lastActivityAt: nil, checkpoint: "green", taskRef: "task-1")
            ]),
            availability: BossDashboardAvailability(
                machineAvailable: false, needsMeAvailable: true, codingAvailable: true,
                issues: ["machine: unreachable"]))
    }

    // MARK: - Enumerated state-set

    func testDashboard_empty() throws {
        let model = try makeVM(seedDecision: false)
        XCTAssertNil(model.inboxDoor, "provenance: empty inbox → no door")
        XCTAssertNil(model.bossDashboard, "provenance: no dashboard set")
        let tree = try ViewSnapshotHost.snapshotText(of: BossDashboardView(model: model))
        XCTAssertFalse(tree.contains("waiting on you"), "empty: no door:\n\(tree)")
        XCTAssertTrue(tree.contains("Show Advanced"), "the collapsed-arm button (showsAdvanced==false):\n\(tree)")
        try assertViewSnapshot(of: BossDashboardView(model: model), named: "BossDashboardView.empty")
    }

    func testDashboard_doorOnly() throws {
        let model = try makeVM(seedDecision: true)
        XCTAssertEqual(model.inboxDoor?.count, 1, "provenance: one open decision → the door")
        let tree = try ViewSnapshotHost.snapshotText(of: BossDashboardView(model: model))
        XCTAssertTrue(tree.contains("1 waiting on you"), "door: the pill renders:\n\(tree)")
        try assertViewSnapshot(of: BossDashboardView(model: model), named: "BossDashboardView.doorOnly")
    }

    func testDashboard_watchError() throws {
        let model = try makeVM(seedDecision: false)
        model.bossWatchLastError = "transport down: ECONNREFUSED 127.0.0.1:6876"
        model.bossWatchConsecutiveFailures = 3
        model.bossWatchIsEnabled = true
        let tree = try ViewSnapshotHost.snapshotText(of: BossDashboardView(model: model))
        XCTAssertTrue(tree.contains("Your agent isn't answering yet"),
                      "watchError: the persistent banner renders:\n\(tree)")
        XCTAssertFalse(tree.contains("ECONNREFUSED"),
                       "the raw error is NEVER interpolated (seam-derived copy):\n\(tree)")
        try assertViewSnapshot(of: BossDashboardView(model: model), named: "BossDashboardView.watchError")
    }

    func testDashboard_checkInRunning() throws {
        let model = try makeVM(seedDecision: false)
        model.bossCheckInIsRunning = true
        let tree = try ViewSnapshotHost.snapshotText(of: BossDashboardView(model: model))
        XCTAssertTrue(tree.contains("Asking boss…"), "checkInRunning: the spinner row renders:\n\(tree)")
        try assertViewSnapshot(of: BossDashboardView(model: model), named: "BossDashboardView.checkInRunning")
    }

    func testDashboard_fullDashboard() throws {
        let model = try makeVM(seedDecision: true)
        model.bossWatchLastError = "transport down"
        model.bossWatchConsecutiveFailures = 3
        model.bossWatchIsEnabled = true
        model.bossCheckInIsRunning = true
        model.bossDashboard = dashboard()
        model.bossCheckInAnswer = "Everything is green; nothing needs you."
        let tree = try ViewSnapshotHost.snapshotText(of: BossDashboardView(model: model))
        // Every gate firing at once.
        XCTAssertTrue(tree.contains("1 waiting on you"), "door fires:\n\(tree)")
        XCTAssertTrue(tree.contains("Your agent isn't answering yet"), "watch-error banner fires:\n\(tree)")
        XCTAssertTrue(tree.contains("Asking boss…"), "check-in spinner fires:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="needs me""#), "metrics strip fires:\n\(tree)")
        XCTAssertTrue(tree.contains("Mailbox warnings: machine: unreachable"), "mailbox warning fires:\n\(tree)")
        XCTAssertTrue(tree.contains("Boss Reply"), "boss-reply block fires:\n\(tree)")
        XCTAssertTrue(tree.contains("Everything is green; nothing needs you."), "the answer renders:\n\(tree)")
        XCTAssertTrue(tree.contains("Review the rename – decision ready"), "needs-me column fires:\n\(tree)")
        XCTAssertTrue(tree.contains("Habit History"), "habit panel fires:\n\(tree)")
        try assertViewSnapshot(of: BossDashboardView(model: model), named: "BossDashboardView.fullDashboard")
    }

    // MARK: - Class 4 — the showsAdvanced expanded arm, DRIVEN via the init seam

    /// Collapsed (default) arm: `showsAdvanced == false` → the "Show Advanced" label + the
    /// `chevron.down` glyph, and NONE of the expanded subviews.
    func testDashboard_showsAdvanced_collapsedByDefault() throws {
        let model = try makeVM(seedDecision: false)
        let tree = try ViewSnapshotHost.snapshotText(of: BossDashboardView(model: model))
        XCTAssertTrue(tree.contains("Show Advanced"), "collapsed: the Show (not Hide) label:\n\(tree)")
        XCTAssertFalse(tree.contains("Hide Advanced"), "collapsed: never the expanded Hide label:\n\(tree)")
        XCTAssertTrue(tree.contains("chevron.down"), "collapsed: the down chevron (not up):\n\(tree)")
    }

    /// Expanded arm (the previously-carved `if showsAdvanced` block): the
    /// `init(initialShowsAdvanced: true)` seam seeds `@State showsAdvanced = true`, so the
    /// expanded block renders — the "Hide Advanced" label + the `chevron.up` glyph + the
    /// expanded subviews (Support Diagnostics from MachineRuntimeView, the Recovery Drill).
    /// (No committed snapshot: the embedded MachineRuntimeView reads machine-local login-item
    /// state; we assert deterministic markers instead.)
    func testDashboard_showsAdvanced_expandedArm_rendersAdvancedSubviews() throws {
        let model = try makeVM(seedDecision: false)
        let tree = try ViewSnapshotHost.snapshotText(
            of: BossDashboardView(model: model, initialShowsAdvanced: true))
        XCTAssertTrue(tree.contains("Hide Advanced"), "expanded: the Hide (not Show) label:\n\(tree)")
        XCTAssertFalse(tree.contains("Show Advanced"), "expanded: never the collapsed Show label")
        XCTAssertTrue(tree.contains("chevron.up"), "expanded: the up chevron (not down)")
        // Markers of the expanded-only subviews (MachineRuntimeView's Support-Diagnostics row +
        // the RecoveryDrillView), which only render inside the `if showsAdvanced` block.
        XCTAssertTrue(tree.contains("Support Diagnostics"),
                      "expanded: MachineRuntimeView's Support-Diagnostics row renders:\n\(tree)")
        XCTAssertTrue(tree.contains("Recovery Drill"),
                      "expanded: the RecoveryDrillView renders:\n\(tree)")
    }

    /// The expand/collapse gate flips the tree (mutation-verified negative control): the
    /// expanded subviews appear ONLY in the `initialShowsAdvanced: true` render.
    func testDashboard_showsAdvanced_negativeControl_gateFlipsTree() throws {
        let model = try makeVM(seedDecision: false)
        let collapsed = try ViewSnapshotHost.snapshotText(of: BossDashboardView(model: model))
        let expanded = try ViewSnapshotHost.snapshotText(
            of: BossDashboardView(model: model, initialShowsAdvanced: true))
        XCTAssertNotEqual(collapsed, expanded, "the showsAdvanced gate must flip the tree")
        XCTAssertFalse(collapsed.contains("Recovery Drill"), "collapsed: no Recovery Drill")
        XCTAssertTrue(expanded.contains("Recovery Drill"), "expanded: the Recovery Drill renders")
    }

    /// The `.onChange(of: transcriptSearchFocusToken)` closure (the ⌘K "Search Transcripts"
    /// reveal) sets `showsAdvanced = true`. ViewInspector invokes it via `callOnChange`.
    func testDashboard_transcriptSearchFocusToken_onChangeRevealsAdvanced() throws {
        let model = try makeVM(seedDecision: false)
        let view = BossDashboardView(model: model)
        XCTAssertNoThrow(
            try view.inspect().find(ViewType.ScrollView.self)
                .callOnChange(oldValue: 0, newValue: 1),
            "the transcriptSearchFocusToken onChange closure (showsAdvanced = true) executes")
    }

    /// The "Show/Hide Advanced" button ACTION (`showsAdvanced.toggle()`) is invoked by a tap.
    func testDashboard_showAdvancedButton_tapInvokesToggle() throws {
        let model = try makeVM(seedDecision: false)
        XCTAssertNoThrow(
            try BossDashboardView(model: model).inspect().find(button: "Show Advanced").tap(),
            "the Show-Advanced button action (showsAdvanced.toggle()) executes")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The model gates flip whole captured subtrees: the door/error/check-in/dashboard
    /// each appear only when their seam is populated.
    func testDashboard_negativeControl_gatesFlipTree() throws {
        let empty = try ViewSnapshotHost.snapshotText(of: BossDashboardView(model: try makeVM(seedDecision: false)))
        let door = try ViewSnapshotHost.snapshotText(of: BossDashboardView(model: try makeVM(seedDecision: true)))
        XCTAssertNotEqual(empty, door, "the inboxDoor gate must flip the tree")
        XCTAssertFalse(empty.contains("waiting on you"), "empty: no door:\n\(empty)")
        XCTAssertTrue(door.contains("1 waiting on you"), "door: the pill renders:\n\(door)")

        let withDash = try makeVM(seedDecision: false)
        withDash.bossDashboard = dashboard()
        let dashTree = try ViewSnapshotHost.snapshotText(of: BossDashboardView(model: withDash))
        XCTAssertNotEqual(empty, dashTree, "the dashboard gate must flip the tree")
        XCTAssertTrue(dashTree.contains("Mailbox warnings"), "dashboard: the warning + strips render:\n\(dashTree)")
        XCTAssertFalse(empty.contains("Mailbox warnings"), "empty: no dashboard content:\n\(empty)")
    }

    // MARK: - Determinism (P3)

    func testDashboard_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let builders: [(String, () throws -> WorkbenchViewModel)] = [
            ("empty", { try self.makeVM(seedDecision: false) }),
            ("doorOnly", { try self.makeVM(seedDecision: true) }),
            ("full", {
                let m = try self.makeVM(seedDecision: true)
                m.bossWatchLastError = "transport down"
                m.bossWatchConsecutiveFailures = 3
                m.bossCheckInIsRunning = true
                m.bossDashboard = self.dashboard()
                m.bossCheckInAnswer = "Everything is green."
                return m
            })
        ]
        for (name, makeModel) in builders {
            let model = try makeModel()
            let a = try ViewSnapshotHost.snapshotText(of: BossDashboardView(model: model))
            let b = try ViewSnapshotHost.snapshotText(of: BossDashboardView(model: model))
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }
}
#endif
