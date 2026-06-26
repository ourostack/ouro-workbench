#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C4-5 — `DecisionInboxSheet` (`:2218`) enumerated state-set (the U2 injectable-clock view).
///
/// The sheet drives off `model.state.openInboxGroups(now:)` — the open, triageable queue at
/// `now`. The view carries the U2 injectable `var now: Date? = nil` (production: the
/// `TimelineView(.periodic)` `context.date`; test: a FIXED `Date`), threaded into the grouping so
/// the queue is deterministic. Its body branches:
///   - `if showFullLog` (`@State private`, initial `false` → `inspect()` always renders the INBOX,
///     never the full-log — the full-log arm is reachable only via the in-view Picker, recorded as
///     structurally-unreachable below, not fabricated).
///   - else `if groups.isEmpty` (`:2272`) → the "Inbox zero" empty state (+ the "View full
///     decision log" button when `!decisionLog.isEmpty`).
///   - else → `inboxQueue(groups)` (`:2275`): the severity-headed `ForEach(groups)` /
///     `ForEach(group.decisions)` of `DecisionLogRow(mode: .inbox, …)`.
///
/// **Clock (AN-007 + U2 — the C4 hazard, BOTH seams).** Two clock surfaces are pinned:
///   (1) the GROUPING clock — the injected FIXED `now:` drives `openInboxGroups(now:)` so the open
///       queue is deterministic (a never-snoozed decision is open at any `now`, but the fixed
///       `now` removes the live-`Date()` default entirely).
///   (2) the ROW TIMESTAMP — the injected `.gmt`/`en_GB` threaded to every embedded
///       `DecisionLogRow` renders each `occurredAt` byte-identically (the AN-007 migration).
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` store seam (AN-001). The decision log is
/// persisted through `WorkbenchStore.save` → VM; the open-queue derivation is the REAL
/// `WorkspaceState.openInboxGroups(now:)` (the same the live sheet uses). Each `BossInboxDecision`
/// via its REAL initializer with a FIXED `occurredAt`. NO hand-assembled state.
///
/// **Non-vacuity (P2).** The negative control flips the `groups.isEmpty` gate: an open escalate
/// decision → the severity-grouped queue (the severity label + the row session name render); a
/// resolved decision → "Inbox zero". The two trees differ; named content appears/vanishes.
@MainActor
final class DecisionInboxSheetTests: XCTestCase {

    /// A FIXED `now` for the grouping clock — 2026-01-02 12:00:00 UTC (after every fixture's
    /// `occurredAt`, so nothing reads as future-dated).
    private static let fixedNow = Date(timeIntervalSince1970: 1_767_355_200)
    /// The decisions' FIXED occurredAt — before `fixedNow`.
    private static let fixedDate = Date(timeIntervalSince1970: 1_767_323_045)
    private static let clockLocale = Locale(identifier: "en_GB")
    private static let decisionId = UUID(uuidString: "DEC15102-0000-0000-0000-00000000000C")!

    private func makeVM(decisionLog: [BossInboxDecision]) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c4-inbox-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        var state = WorkspaceState(boss: BossAgentSelection(agentName: "boss"))
        state.decisionLog = decisionLog
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    /// An OPEN escalate decision (needsHuman + no triage → open at any `now`).
    private func openDecision() -> BossInboxDecision {
        BossInboxDecision(
            id: Self.decisionId,
            occurredAt: Self.fixedDate,
            source: "boss:slugger",
            sessionName: "deploy-runner",
            friendName: "Sam",
            prompt: "Apply the migration?",
            kind: .escalate,
            proposedInput: "y",
            preferenceCited: "Sam always approves staging migrations",
            confidence: 0.82,
            reasoning: "Matches the team's standing preference.",
            status: .recorded
        )
    }

    /// A RESOLVED decision (triaged closed → NOT open → inbox-zero, but the log is non-empty).
    /// `.resolved(at:)` carries a FIXED close-time so the fixture stays deterministic.
    private func resolvedDecision() -> BossInboxDecision {
        var d = openDecision()
        d.triage = .resolved(at: Self.fixedDate)
        return d
    }

    private func sheet(_ model: WorkbenchViewModel) -> DecisionInboxSheet {
        DecisionInboxSheet(model: model, now: Self.fixedNow, timeZone: .gmt, locale: Self.clockLocale)
    }

    // MARK: - Enumerated state-set

    /// The severity-grouped open queue (the `inboxQueue` arm).
    func testInbox_queue() throws {
        let model = try makeVM(decisionLog: [openDecision()])
        let groups = model.state.openInboxGroups(now: Self.fixedNow)
        XCTAssertFalse(groups.isEmpty, "provenance: an open escalate decision yields a queue")
        XCTAssertEqual(groups.first?.severity, .elevated, "provenance: escalate → .elevated tier")
        try assertViewSnapshot(of: sheet(model), named: "DecisionInboxSheet.queue")
    }

    /// "Inbox zero" — decisions exist but all are resolved/snoozed (the `groups.isEmpty` arm with
    /// a non-empty log → the "View full decision log" button also renders).
    func testInbox_zeroWithLog() throws {
        let model = try makeVM(decisionLog: [resolvedDecision()])
        let groups = model.state.openInboxGroups(now: Self.fixedNow)
        XCTAssertTrue(groups.isEmpty, "provenance: a resolved decision leaves the open queue empty")
        XCTAssertFalse(model.state.decisionLog.isEmpty, "provenance: the log is non-empty")
        try assertViewSnapshot(of: sheet(model), named: "DecisionInboxSheet.zeroWithLog")
    }

    /// "Inbox zero" with NO log at all (the empty-empty arm — no "View full log" button).
    func testInbox_zeroNoLog() throws {
        let model = try makeVM(decisionLog: [])
        XCTAssertTrue(model.state.openInboxGroups(now: Self.fixedNow).isEmpty, "provenance: empty queue")
        try assertViewSnapshot(of: sheet(model), named: "DecisionInboxSheet.zeroNoLog")
    }

    // MARK: - @State showFullLog arm (structurally-unreachable — recorded, not fabricated)

    /// `@State private var showFullLog` defaults to `false`; `inspect()` renders the INBOX view,
    /// never the full-log (reachable only via the in-view Picker). Asserted via the captured tree
    /// (the "Decision Inbox" title, not "Boss Decision Log"), classifying the unreachable arm.
    func testInbox_fullLogArm_isUnreachableFalseByDefault() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: sheet(try makeVM(decisionLog: [openDecision()])))
        XCTAssertTrue(tree.contains("Decision Inbox"),
                      "the initial @State showFullLog==false renders the Inbox title:\n\(tree)")
    }

    // MARK: - Determinism (P3 — both clock seams)

    func testInbox_determinism_byteIdenticalTwiceNoLeak() throws {
        for (name, log) in [("queue", [openDecision()]), ("zeroWithLog", [resolvedDecision()]), ("zeroNoLog", [])] {
            let model = try makeVM(decisionLog: log)
            let a = try ViewSnapshotHost.snapshotText(of: sheet(model))
            let b = try ViewSnapshotHost.snapshotText(of: sheet(model))
            XCTAssertEqual(a, b, "\(name) must be byte-identical twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 — mutation-verified)

    func testInbox_negativeControl_queueGateFlipsTree() throws {
        let queue = try ViewSnapshotHost.snapshotText(of: sheet(try makeVM(decisionLog: [openDecision()])))
        let zero = try ViewSnapshotHost.snapshotText(of: sheet(try makeVM(decisionLog: [resolvedDecision()])))

        XCTAssertNotEqual(queue, zero, "the open-queue gate must drive the tree")
        // Queue arm: the severity label + the row session name render.
        XCTAssertTrue(queue.contains("deploy-runner"), "queue: the row session name renders:\n\(queue)")
        XCTAssertTrue(queue.contains("Resolve"), "queue: the inbox-mode triage control renders")
        XCTAssertFalse(queue.contains("Inbox zero"), "queue: not the empty state")
        // Zero arm: "Inbox zero" + the "View full decision log" button (log non-empty).
        XCTAssertTrue(zero.contains("Inbox zero"), "zero: the inbox-zero copy renders:\n\(zero)")
        XCTAssertTrue(zero.contains("View full decision log"), "zero: the full-log button renders (log non-empty)")
        XCTAssertFalse(zero.contains("deploy-runner"), "zero: no open row content")
    }
}
#endif
