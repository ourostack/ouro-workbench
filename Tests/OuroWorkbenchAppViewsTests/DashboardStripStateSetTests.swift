#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C2-6 — the dashboard STRIPS: `DashboardMetricsStrip` and `WorkbenchVisibilityStrip`.
/// Both compose the C2-2 metric chips with dashboard / visibility DATA, so each per-metric
/// value (daemon status, needs-me/coding/blocked/habit counts, daemon mode; owed/returns/
/// claims/inbox/recover) is a CAPTURED `Text` value-flip driven by the snapshot. Re-confirmed
/// LOGIC at execution (the C1 `SidebarCountBadge` value-flip standard) — the first-pass
/// branchless binning is superseded.
///
/// **Provenance (P2).**
///  - `DashboardMetricsStrip`: the `BossDashboardSnapshot` is provenance-built through the
///    REAL producer `BossDashboardBuilder().build(...)` from a real `MailboxMachineView` /
///    `MailboxNeedsMeView` / `MailboxCodingSummary` (the exact builder `refreshBossDashboard`
///    calls). The per-chip `MetricValuePresentation` is then resolved by the strip's own
///    real `MetricValuePresentation.resolve` calls.
///  - `WorkbenchVisibilityStrip`: the `WorkbenchVisibilitySnapshot` is provenance-built
///    through the REAL producer `WorkbenchVisibilityBuilder().build(state:workCard:now:)` —
///    the EXACT builder `refreshWorkbenchVisibility()` calls — fed a real `WorkspaceState`
///    + a real `WorkCardReadResult` (`.available(decoded OuroWorkCard)` for live counts,
///    `.unavailable(issue)` for the degraded arm). NO hand-assembled snapshot.
///
/// **Determinism (P3).** Fixed daemon strings + fixed counts; the work-card JSON carries
/// fixed counts + a relative `arc/...` locator (no machine path); a fixed `now`. The
/// strips' `.help(...)` tooltips are dropped by the host (AN-004). Byte-identical twice +
/// `!contains("/Users/")`.
///
/// **Enumerated state-set:**
///   `DashboardMetricsStrip`:
///     - `allAvailable` — every probe available → the daemon status/mode + the real
///         needs-me/coding/blocked/habit COUNT `Text`s.
///     - `someUnavailable` — machine + coding probes failed (availability issues) → the
///         daemon/mode/coding/blocked chips collapse to the muted dash + info glyph, while
///         needs-me/habits stay real (the per-chip availability flip).
///   `WorkbenchVisibilityStrip`:
///     - `available` — a live work card → owed=3 / returns=2 real counts + "claims ok" +
///         the readiness status `Text`.
///     - `degraded` — an unavailable work card → owed/returns collapse to the dash +
///         info glyph, "claims unknown", readiness "degraded".
@MainActor
final class DashboardStripStateSetTests: XCTestCase {

    private static let fixedNow = Date(timeIntervalSince1970: 1_767_323_045)

    // MARK: - DashboardMetricsStrip (real BossDashboardBuilder)

    private func machine(daemonStatus: String, daemonMode: String) -> MailboxMachineView {
        MailboxMachineView(
            overview: MailboxMachineOverview(
                observedAt: "2026-06-11T10:00:00Z",
                primaryEntryPoint: "http://127.0.0.1:6876",
                daemon: MailboxMachineDaemonSummary(status: daemonStatus, mode: daemonMode, mailboxUrl: "http://127.0.0.1:6876"),
                runtime: MailboxRuntimeSummary(version: "0.1.0"),
                totals: MailboxMachineTotals(openObligations: 0, activeCodingAgents: 2, blockedCodingAgents: 1)
            ),
            agents: [
                MailboxMachineAgentView(
                    agentName: "boss",
                    enabled: true,
                    attention: MailboxAttentionSummary(level: "active", label: "active"),
                    obligations: MailboxCountSummary(openCount: 0),
                    coding: MailboxCountSummary(activeCount: 2, blockedCount: 1))
            ])
    }

    private func dashboard(available: Bool) -> BossDashboardSnapshot {
        let availability: BossDashboardAvailability = available
            ? .complete
            : BossDashboardAvailability(
                machineAvailable: false,
                needsMeAvailable: true,
                codingAvailable: false,
                habitHistoryAvailable: true,
                issues: ["machine: unreachable", "coding: probe failed"])
        return BossDashboardBuilder().build(
            boss: BossAgentSelection(agentName: "boss"),
            machine: available ? machine(daemonStatus: "running", daemonMode: "dev") : nil,
            needsMe: MailboxNeedsMeView(items: []),
            coding: MailboxCodingSummary(totalCount: 2, activeCount: 2, blockedCount: 1, items: []),
            availability: availability)
    }

    func testMetricsStrip_allAvailable() throws {
        let dash = dashboard(available: true)
        XCTAssertTrue(dash.availability.machineAvailable && dash.availability.codingAvailable,
                      "provenance: the builder produced an all-available dashboard")
        XCTAssertEqual(dash.daemonStatus, "running")
        let tree = try ViewSnapshotHost.snapshotText(of: DashboardMetricsStrip(dashboard: dash, onRetry: {}))
        XCTAssertTrue(tree.contains(#"text="running""#), "the daemon status renders:\n\(tree)")
        XCTAssertFalse(tree.contains("info.circle"), "all-available: no unavailable glyphs:\n\(tree)")
        try assertViewSnapshot(of: DashboardMetricsStrip(dashboard: dash, onRetry: {}), named: "DashboardMetricsStrip.allAvailable")
    }

    func testMetricsStrip_someUnavailable() throws {
        let dash = dashboard(available: false)
        XCTAssertFalse(dash.availability.machineAvailable, "provenance: the machine probe failed")
        XCTAssertFalse(dash.availability.codingAvailable, "provenance: the coding probe failed")
        let tree = try ViewSnapshotHost.snapshotText(of: DashboardMetricsStrip(dashboard: dash, onRetry: {}))
        XCTAssertTrue(tree.contains("info.circle"), "unavailable probes: the info glyph renders:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="—""#), "unavailable probes: the muted dash renders:\n\(tree)")
        try assertViewSnapshot(of: DashboardMetricsStrip(dashboard: dash, onRetry: {}), named: "DashboardMetricsStrip.someUnavailable")
    }

    // MARK: - WorkbenchVisibilityStrip (real WorkbenchVisibilityBuilder)

    private func visibility(available: Bool) throws -> WorkbenchVisibilitySnapshot {
        let state = WorkspaceState(boss: BossAgentSelection(agentName: "boss"))
        let workCard: WorkCardReadResult
        if available {
            let card = try JSONDecoder().decode(OuroWorkCard.self, from: Data(Self.availableWorkCardJSON.utf8))
            workCard = .available(card)
        } else {
            workCard = .unavailable(WorkbenchVisibilityIssue(
                code: "work_card_unavailable", severity: "unavailable",
                source: "ouro work card", detail: "Work Card probe timed out"))
        }
        return WorkbenchVisibilityBuilder().build(state: state, workCard: workCard, now: Self.fixedNow)
    }

    func testVisibilityStrip_available() throws {
        let snapshot = try visibility(available: true)
        XCTAssertEqual(snapshot.agentWork.counts.owed, 3, "provenance: the work card's owed count")
        XCTAssertEqual(snapshot.readiness.status, .available)
        let tree = try ViewSnapshotHost.snapshotText(of: WorkbenchVisibilityStrip(snapshot: snapshot, onOpenInbox: nil, onRetry: {}))
        XCTAssertTrue(tree.contains(#"text="3""#), "owed=3 renders:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="ok""#), "claims ok renders:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="available""#), "readiness status renders:\n\(tree)")
        try assertViewSnapshot(of: WorkbenchVisibilityStrip(snapshot: snapshot, onOpenInbox: nil, onRetry: {}), named: "WorkbenchVisibilityStrip.available")
    }

    func testVisibilityStrip_degraded() throws {
        let snapshot = try visibility(available: false)
        XCTAssertNil(snapshot.agentWork.counts.owed, "provenance: an unavailable work card → nil counts")
        XCTAssertEqual(snapshot.readiness.status, .degraded)
        let tree = try ViewSnapshotHost.snapshotText(of: WorkbenchVisibilityStrip(snapshot: snapshot, onOpenInbox: nil, onRetry: {}))
        XCTAssertTrue(tree.contains("info.circle"), "degraded: the info glyph renders:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="unknown""#), "claims unknown renders:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="degraded""#), "readiness degraded renders:\n\(tree)")
        try assertViewSnapshot(of: WorkbenchVisibilityStrip(snapshot: snapshot, onOpenInbox: nil, onRetry: {}), named: "WorkbenchVisibilityStrip.degraded")
    }

    // MARK: - AN-R2-03 — energy-0 r2 close: the live inbox door

    /// An OPEN escalate decision (needsHuman + no triage → open at any `now`) — the same
    /// provenance `DecisionInboxSheetTests` uses. Drives `state.openInboxCount(now:)` > 0,
    /// hence `WorkbenchVisibilitySnapshot.decisions.openInbox` > 0.
    private func openInboxState() -> WorkspaceState {
        var state = WorkspaceState(boss: BossAgentSelection(agentName: "boss"))
        state.decisionLog = [BossInboxDecision(
            id: UUID(uuidString: "DEC15102-0000-0000-0000-0000000000A3")!,
            occurredAt: Date(timeIntervalSince1970: 1_767_300_000),  // before fixedNow
            source: "boss:slugger",
            sessionName: "deploy-runner",
            prompt: "Apply the migration?",
            kind: .escalate,
            reasoning: "Matches the standing preference.",
            status: .recorded)]
        return state
    }

    /// A real visibility snapshot whose state carries one open inbox decision (available
    /// work card, so the other chips render real values). Built through the REAL
    /// `WorkbenchVisibilityBuilder` — no hand-assembled snapshot.
    private func visibilityWithOpenInbox() throws -> WorkbenchVisibilitySnapshot {
        let card = try JSONDecoder().decode(OuroWorkCard.self, from: Data(Self.availableWorkCardJSON.utf8))
        return WorkbenchVisibilityBuilder().build(
            state: openInboxState(), workCard: .available(card), now: Self.fixedNow)
    }

    /// The inbox-chip tap arm `tap: (snapshot.decisions.openInbox > 0) ? onOpenInbox : nil`
    /// (`:5757`) only renders the `arrow.up.right` door glyph when BOTH the open count is
    /// positive AND a handler is wired. Every committed strip fixture passed
    /// `onOpenInbox: nil`, so the door arm never rendered — the round-2 mutation sweep
    /// proved it (inverting the ternary left the suite GREEN). Here a real open-inbox
    /// snapshot + a live `onOpenInbox` makes the inbox chip a door, pinned via inline
    /// assert + a recorded reference.
    func testVisibilityStrip_openInboxWithHandler_rendersDoorGlyph() throws {
        let snapshot = try visibilityWithOpenInbox()
        XCTAssertEqual(snapshot.decisions.openInbox, 1,
                       "provenance: one open escalate decision → openInbox == 1")
        let view = WorkbenchVisibilityStrip(snapshot: snapshot, onOpenInbox: {}, onRetry: {})
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="1""#), "the inbox chip shows the open count:\n\(tree)")
        XCTAssertTrue(tree.contains(#"image="arrow.up.right""#),
                      "open inbox + a handler → the inbox chip is a live door:\n\(tree)")
        try assertViewSnapshot(of: view, named: "WorkbenchVisibilityStrip.inboxDoorLive")
    }

    /// Negative control (P2): the door is gated on BOTH the count AND the handler. A
    /// positive count with NO handler stays inert; a handler with a ZERO count stays inert.
    /// Each drops the `arrow.up.right` glyph — proving the gate's two halves are both
    /// load-bearing.
    func testVisibilityStrip_inboxDoor_gatedOnCountAndHandler() throws {
        // Positive count, NO handler → inert.
        let openNoHandler = try ViewSnapshotHost.snapshotText(of: WorkbenchVisibilityStrip(
            snapshot: try visibilityWithOpenInbox(), onOpenInbox: nil, onRetry: {}))
        XCTAssertFalse(openNoHandler.contains(#"image="arrow.up.right""#),
                       "open count but no handler → inert chip:\n\(openNoHandler)")

        // Zero count, WITH handler → inert (the default empty-state snapshot has openInbox 0).
        let zeroWithHandler = try ViewSnapshotHost.snapshotText(of: WorkbenchVisibilityStrip(
            snapshot: try visibility(available: true), onOpenInbox: {}, onRetry: {}))
        XCTAssertEqual((try visibility(available: true)).decisions.openInbox, 0,
                       "provenance: the available fixture has an empty inbox")
        XCTAssertFalse(zeroWithHandler.contains(#"image="arrow.up.right""#),
                       "zero count even with a handler → inert chip:\n\(zeroWithHandler)")

        // Both → the door renders. Differs from both inert trees.
        let live = try ViewSnapshotHost.snapshotText(of: WorkbenchVisibilityStrip(
            snapshot: try visibilityWithOpenInbox(), onOpenInbox: {}, onRetry: {}))
        XCTAssertTrue(live.contains(#"image="arrow.up.right""#), "both → the door:\n\(live)")
        XCTAssertNotEqual(live, openNoHandler, "the handler half of the gate must flip the tree")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The per-probe availability + counts drive which chips show a real value vs the
    /// muted dash + info glyph — the captured value/glyph flips both strips exist to surface.
    func testStrips_negativeControl_availabilityFlipsTree() throws {
        let dashOk = try ViewSnapshotHost.snapshotText(of: DashboardMetricsStrip(dashboard: dashboard(available: true), onRetry: {}))
        let dashBad = try ViewSnapshotHost.snapshotText(of: DashboardMetricsStrip(dashboard: dashboard(available: false), onRetry: {}))
        XCTAssertNotEqual(dashOk, dashBad, "the dashboard availability must flip the strip")
        XCTAssertFalse(dashOk.contains("info.circle"), dashOk)
        XCTAssertTrue(dashBad.contains("info.circle"), dashBad)

        let visOk = try ViewSnapshotHost.snapshotText(of: WorkbenchVisibilityStrip(snapshot: try visibility(available: true), onOpenInbox: nil, onRetry: {}))
        let visBad = try ViewSnapshotHost.snapshotText(of: WorkbenchVisibilityStrip(snapshot: try visibility(available: false), onOpenInbox: nil, onRetry: {}))
        XCTAssertNotEqual(visOk, visBad, "the work-card availability must flip the strip")
        XCTAssertTrue(visOk.contains(#"text="3""#), "available: owed=3:\n\(visOk)")
        XCTAssertTrue(visBad.contains("info.circle"), "degraded: the info glyph:\n\(visBad)")
    }

    // MARK: - Determinism (P3)

    func testStrips_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, () throws -> String)] = [
            ("dashAvailable", { try ViewSnapshotHost.snapshotText(of: DashboardMetricsStrip(dashboard: self.dashboard(available: true), onRetry: {})) }),
            ("dashUnavailable", { try ViewSnapshotHost.snapshotText(of: DashboardMetricsStrip(dashboard: self.dashboard(available: false), onRetry: {})) }),
            ("visAvailable", { try ViewSnapshotHost.snapshotText(of: WorkbenchVisibilityStrip(snapshot: try self.visibility(available: true), onOpenInbox: nil, onRetry: {})) }),
            ("visDegraded", { try ViewSnapshotHost.snapshotText(of: WorkbenchVisibilityStrip(snapshot: try self.visibility(available: false), onOpenInbox: nil, onRetry: {})) })
        ]
        for (name, make) in cases {
            let a = try make()
            let b = try make()
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }

    /// A real `OuroWorkCard` JSON (fixed counts, a relative `arc/...` locator — no machine
    /// value) — the exact decode shape the live `OuroWorkCardReader` yields.
    private static let availableWorkCardJSON = """
    {
      "schemaVersion": 1,
      "projection": { "owner": "arc/work-card", "scope": "durable-arc-work", "relationToActiveWorkFrame": "complements-live-turn-frame" },
      "agent": "boss",
      "generatedAt": "2026-06-08T12:00:00.000Z",
      "degraded": { "status": "available", "issues": [] },
      "counts": { "owed": 3, "returnObligations": 2, "activePackets": 1, "evolutionCases": 0, "waitingOnHuman": 0, "unverifiedClaims": 4, "staleRiskyClaims": 5 },
      "claims": { "available": true, "unavailableReason": null, "counts": { "unverified": 1, "partial": 2, "failed": 3, "unverifiable": 4, "staleRisky": 5, "verified": 7 } },
      "nextAction": { "actor": "agent", "summary": "Proceed with the packet.", "source": { "kind": "ponder_packet", "locator": "arc/packets/good.json", "freshness": "current", "redaction": "none" } },
      "sources": []
    }
    """
}
#endif
