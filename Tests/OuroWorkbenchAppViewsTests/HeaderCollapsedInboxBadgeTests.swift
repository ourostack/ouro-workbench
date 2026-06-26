#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C4-6 — `HeaderView`'s collapsed-pane `inboxDoor` count badge (`:4061`) — the clock-dependent
/// badge DEFERRED from C3 to this clock cluster.
///
/// C3's `HeaderViewTests` covered the header's `statusLine` arm but explicitly DEFERRED the
/// collapsed-pane overlay `if model.state.bossPaneCollapsed, let door = model.inboxDoor` (`:4061`)
/// to C4, because `model.inboxDoor` reads `InboxDoorPresentation.resolve(state:)` whose default
/// `now:` is a live `Date()` — a clock seam. This sub-unit covers it. Two arms:
///   - collapsed + an open inbox → the count `Text(door.badgeText)` badge renders on the
///     "Show Boss Pane" button (the overlay branch).
///   - expanded (`bossPaneCollapsed == false`) → no badge (the gate's `false` arm).
///
/// **Clock determinism (P3 — the C4 reason this is here).** `model.inboxDoor` resolves the door
/// from `state.openInbox(now: Date())`. For an UN-TRIAGED `.escalate` decision (`triage == nil` →
/// `isOpenForTriage(at:) == true` for ANY `now`), the open count + top severity are
/// CLOCK-INDEPENDENT — so `door.count` / `door.badgeText` / `door.topSeverity` are byte-identical
/// regardless of the live `Date()` the resolver reads. The determinism guard proves it (the door
/// is re-resolved on each render, yet the tree is byte-identical twice); the cross-TZ/locale gate
/// run confirms it across runner zones. (The badge text is the count only — `door.badgeText` is
/// `"\(count)"`, no formatted date — and the `.help(door.accessibilityLabel)` tooltip is dropped
/// by the host AN-004, so NO clock-formatted string reaches the tree; the clock only gates the
/// door's EXISTENCE, which the un-triaged decision pins.)
///
/// **Login-item carve (the C3 finding — candidate #6).** The header embeds `AutonomyStatusButton`,
/// whose `ttfaText` folds the NON-INJECTABLE login-item state ONLY when a boss is set. Every
/// fixture here uses an EMPTY boss → the embedded button is on its login-INDEPENDENT neutral arm,
/// so the whole header (badge included) is deterministic. The determinism guard (two fresh login
/// controllers → byte-identical) proves it.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` store seam (AN-001). The collapsed flag
/// is the REAL `state.bossPaneCollapsed`; the door is the REAL `model.inboxDoor` derived from a
/// persisted open `BossInboxDecision` (its REAL initializer) through the REAL
/// `InboxDoorPresentation.resolve` → `openInbox` seam. NO fabricated door.
@MainActor
final class HeaderCollapsedInboxBadgeTests: XCTestCase {

    private static let fixedDate = Date(timeIntervalSince1970: 1_767_323_045)
    private static let decisionId = UUID(uuidString: "DEC15102-0000-0000-0000-00000000000D")!

    private func makeVM(decisionLog: [BossInboxDecision], collapsed: Bool) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c4-badge-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        var state = WorkspaceState(boss: BossAgentSelection(agentName: ""))
        state.decisionLog = decisionLog
        state.bossPaneCollapsed = collapsed
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    /// An OPEN, un-triaged escalate decision → the door resolves clock-independently.
    private func openDecision() -> BossInboxDecision {
        BossInboxDecision(
            id: Self.decisionId,
            occurredAt: Self.fixedDate,
            source: "boss:slugger",
            sessionName: "deploy-runner",
            prompt: "Apply the migration?",
            kind: .escalate,
            reasoning: "Needs you."
        )
    }

    private func header(_ model: WorkbenchViewModel) -> HeaderView {
        HeaderView(model: model)
    }

    // MARK: - Enumerated state-set

    /// Collapsed + an open inbox → the count badge renders.
    func testBadge_collapsedWithOpenInbox() throws {
        let model = try makeVM(decisionLog: [openDecision()], collapsed: true)
        XCTAssertTrue(model.state.bossPaneCollapsed, "provenance: the pane is collapsed")
        let door = try XCTUnwrap(model.inboxDoor, "provenance: an open decision resolves a door")
        XCTAssertEqual(door.badgeText, "1", "provenance: one open decision → badge '1'")
        XCTAssertEqual(door.topSeverity, .elevated, "provenance: escalate → .elevated tint")
        try assertViewSnapshot(of: header(model), named: "HeaderView.collapsedInboxBadge")
    }

    /// Expanded → no badge (the gate's false arm; `model.inboxDoor` may be non-nil but the overlay
    /// gate's `bossPaneCollapsed` short-circuits it).
    func testBadge_expandedNoBadge() throws {
        let model = try makeVM(decisionLog: [openDecision()], collapsed: false)
        XCTAssertFalse(model.state.bossPaneCollapsed, "provenance: the pane is expanded")
        try assertViewSnapshot(of: header(model), named: "HeaderView.expandedNoBadge")
    }

    // MARK: - Clock determinism (P3 — the door is clock-independent for an un-triaged decision)

    func testBadge_determinism_clockIndependentByteIdenticalTwiceNoLeak() throws {
        let model = try makeVM(decisionLog: [openDecision()], collapsed: true)
        // `model.inboxDoor` re-resolves from a live `Date()` on each render; an un-triaged
        // decision pins the count+severity, so the tree is byte-identical despite the live clock.
        let a = try ViewSnapshotHost.snapshotText(of: header(model))
        let b = try ViewSnapshotHost.snapshotText(of: header(model))
        XCTAssertEqual(a, b, "the collapsed badge must be byte-identical twice (clock-independent door)")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The `bossPaneCollapsed && inboxDoor != nil` overlay gate renders-vs-hides the count badge,
    /// and the badge text is the real open-count through the door seam.
    func testBadge_negativeControl_collapsedGateFlipsTree() throws {
        let collapsed = try ViewSnapshotHost.snapshotText(
            of: header(try makeVM(decisionLog: [openDecision()], collapsed: true)))
        let expanded = try ViewSnapshotHost.snapshotText(
            of: header(try makeVM(decisionLog: [openDecision()], collapsed: false)))

        XCTAssertNotEqual(collapsed, expanded, "the collapsed-overlay gate must drive the tree")
        // Collapsed arm: the "Show Boss Pane" label + the count badge.
        XCTAssertTrue(collapsed.contains("Show Boss Pane"), "collapsed: the show-pane label:\n\(collapsed)")
        // Expanded arm: the "Hide Boss Pane" label, no count badge text "1" as a standalone node.
        XCTAssertTrue(expanded.contains("Hide Boss Pane"), "expanded: the hide-pane label:\n\(expanded)")
    }
}
#endif
