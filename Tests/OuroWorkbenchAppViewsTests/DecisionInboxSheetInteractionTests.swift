#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B6 — `DecisionInboxSheet` (`:2235`) INTERACTION drive-to-100%.
///
/// The C4 `DecisionInboxSheetTests` drove the inbox RENDER arms (queue / inbox-zero) and recorded
/// the `showFullLog == true` arm as structurally-unreachable. This suite closes the residual:
///
///   - **`showFullLog == true` family** (L2270/L2273 the header ternary true arms; L2293 the
///     `if showFullLog` true branch; the whole `fullLog` `@ViewBuilder` L2371–L2392, BOTH the
///     empty-log and populated-log arms): driven through the sanctioned `init(initialShowFullLog:)`
///     seam (the in-view Picker / "View full decision log" toggle writes `@State`, which
///     ViewInspector re-seeds per inspect, so a `.tap()` re-render can't reach it — the init seam
///     is the standard `_showFullLog = State(initialValue:)` pattern, prod default UNCHANGED).
///   - **L2286** `Button("Done") { dismiss() }` — tapped (region executes; model untouched).
///   - **L2328/L2329** the inbox row `onTeach` closure (`Task { teachBoss }`) — tapped Teach Menu.
///   - **L2331** `onAcknowledge: { model.acknowledgeDecision(decision) }` — tapped Ack.
///   - **L2332** `onSnooze: { model.snoozeDecision(decision, for: $0) }` — tapped a Snooze item.
///   - **L2333** `onResolve: { model.resolveDecision(decision) }` — tapped Resolve.
///   - **L2358** `Button("View full decision log") { showFullLog = true }` — tapped (action runs).
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` seam; the open queue / full log derive
/// from the REAL `WorkspaceState.openInboxGroups(now:)` / `decisionLog`. The triage closures drive
/// the REAL `acknowledge`/`snooze`/`resolve` Core mutations + audit log.
@MainActor
final class DecisionInboxSheetInteractionTests: XCTestCase {

    private static let fixedNow = Date(timeIntervalSince1970: 1_767_355_200)   // 2026-01-02 12:00 UTC
    private static let fixedDate = Date(timeIntervalSince1970: 1_767_323_045)  // before fixedNow
    private static let clockLocale = Locale(identifier: "en_GB")
    private static let decisionId = UUID(uuidString: "DEC15102-0000-0000-0000-00000000002C")!

    private func makeVM(decisionLog: [BossInboxDecision]) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b6-inbox-\(UUID().uuidString)", isDirectory: true)
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

    private func sheet(
        _ model: WorkbenchViewModel,
        showFullLog: Bool = false
    ) -> DecisionInboxSheet {
        DecisionInboxSheet(model: model, now: Self.fixedNow, timeZone: .gmt,
                           locale: Self.clockLocale, initialShowFullLog: showFullLog)
    }

    // MARK: - L2270 / L2273 / L2293 / fullLog populated (L2371/L2387–L2392)

    /// `showFullLog == true` with a NON-empty log → the header flips to "Boss Decision Log" + the
    /// log subtitle (the ternary true arms), and `fullLog` renders the `ScrollView { ForEach … }`
    /// populated branch (the L2387 else-arm).
    func testInbox_fullLog_populated_rendersLogTitleAndRows() throws {
        let model = try makeVM(decisionLog: [openDecision()])
        let tree = try ViewSnapshotHost.snapshotText(of: sheet(model, showFullLog: true))
        XCTAssertTrue(tree.contains("Boss Decision Log"),
                      "the showFullLog header ternary true arm renders the log title:\n\(tree)")
        XCTAssertTrue(tree.contains("Every decision the boss made about a waiting session, and why"),
                      "the showFullLog subtitle ternary true arm renders")
        XCTAssertTrue(tree.contains("deploy-runner"), "fullLog populated arm renders the row")
        XCTAssertFalse(tree.contains("Decision Inbox"), "not the inbox title in full-log mode")
    }

    /// `showFullLog == true` with an EMPTY log → `fullLog`'s `decisionLog.isEmpty` TRUE branch
    /// (L2372/L2373) renders the "No decisions recorded yet" empty state.
    func testInbox_fullLog_empty_rendersEmptyState() throws {
        let model = try makeVM(decisionLog: [])
        let tree = try ViewSnapshotHost.snapshotText(of: sheet(model, showFullLog: true))
        XCTAssertTrue(tree.contains("Boss Decision Log"), "the log title in full-log mode:\n\(tree)")
        XCTAssertTrue(tree.contains("No decisions recorded yet"),
                      "fullLog empty branch renders the empty state")
    }

    // MARK: - Negative control (P2) — showFullLog flips the whole tree

    func testInbox_negativeControl_showFullLogFlipsTree() throws {
        let model = try makeVM(decisionLog: [openDecision()])
        let inbox = try ViewSnapshotHost.snapshotText(of: sheet(model, showFullLog: false))
        let log = try ViewSnapshotHost.snapshotText(of: sheet(model, showFullLog: true))
        XCTAssertNotEqual(inbox, log, "showFullLog must drive the whole tree")
        XCTAssertTrue(inbox.contains("Decision Inbox"), "inbox arm: the inbox title")
        XCTAssertFalse(inbox.contains("Boss Decision Log"), "inbox arm: not the log title")
        XCTAssertTrue(log.contains("Boss Decision Log"), "log arm: the log title")
        XCTAssertFalse(log.contains("Decision Inbox"), "log arm: not the inbox title")
    }

    // MARK: - L2286 — the Done button

    func testInbox_doneButton_tapRunsWithoutMutatingModel() throws {
        let model = try makeVM(decisionLog: [openDecision()])
        let before = model.state.decisionLog
        try sheet(model).inspect().find(button: "Done").tap()
        XCTAssertEqual(model.state.decisionLog, before, "Done runs the dismiss closure, model untouched")
    }

    // MARK: - L2358 — the "View full decision log" button (inbox-zero with a non-empty log)

    /// Inbox-zero (all decisions resolved → empty open queue) but a NON-empty log renders the
    /// "View full decision log" button; tapping it runs `{ showFullLog = true }` (the action body).
    func testInbox_viewFullLogButton_tapRunsAction() throws {
        var resolved = openDecision()
        resolved.triage = .resolved(at: Self.fixedDate)
        let model = try makeVM(decisionLog: [resolved])
        XCTAssertTrue(model.state.openInboxGroups(now: Self.fixedNow).isEmpty, "provenance: empty open queue")
        XCTAssertFalse(model.state.decisionLog.isEmpty, "provenance: non-empty log")
        // The button must be present (inbox-zero + non-empty log), and tapping it runs the action
        // region. (@State doesn't re-render under inspect, but the closure body executes.)
        try sheet(model).inspect().find(button: "View full decision log").tap()
    }

    // MARK: - L2331 — onAcknowledge

    func testInbox_ack_drivesModelAcknowledge() throws {
        let model = try makeVM(decisionLog: [openDecision()])
        XCTAssertFalse(model.state.openInboxGroups(now: Self.fixedNow).isEmpty, "provenance: open queue")
        try sheet(model).inspect().find(button: "Ack").tap()
        XCTAssertTrue(model.state.actionLog.contains { $0.action == "inbox:acknowledge" },
                      "Ack drove model.acknowledgeDecision (audit entry):\n\(model.state.actionLog)")
        XCTAssertTrue(model.state.openInboxGroups(now: Self.fixedNow).isEmpty,
                      "the acknowledged decision left the open queue")
    }

    // MARK: - L2333 — onResolve

    func testInbox_resolve_drivesModelResolve() throws {
        let model = try makeVM(decisionLog: [openDecision()])
        try sheet(model).inspect().find(button: "Resolve").tap()
        XCTAssertTrue(model.state.actionLog.contains { $0.action == "inbox:resolve" },
                      "Resolve drove model.resolveDecision:\n\(model.state.actionLog)")
        XCTAssertTrue(model.state.openInboxGroups(now: Self.fixedNow).isEmpty,
                      "the resolved decision left the open queue")
    }

    // MARK: - L2332 — onSnooze

    func testInbox_snooze_drivesModelSnooze() throws {
        let model = try makeVM(decisionLog: [openDecision()])
        // The Snooze Menu's "1 hour" item fires `onSnooze(3600)` → `model.snoozeDecision(_, for: 3600)`.
        try sheet(model).inspect().find(button: "1 hour").tap()
        XCTAssertTrue(model.state.actionLog.contains { $0.action.hasPrefix("inbox:snooze") },
                      "Snooze drove model.snoozeDecision:\n\(model.state.actionLog)")
        XCTAssertTrue(model.state.openInboxGroups(now: Self.fixedNow).isEmpty,
                      "the snoozed decision left the open queue (snoozed an hour out)")
    }

    // MARK: - fullLog embedded-row onTeach (the `showFullLog == true` ForEach trailing closure)

    /// In full-log mode the populated arm embeds `DecisionLogRow` with its OWN onTeach trailing
    /// closure (`{ autoAdvance in Task { await model.teachBoss(...) } }`) — distinct from the inbox
    /// queue's row closure. Tapping the embedded Teach Menu item drives that closure → teachBoss.
    func testInbox_fullLogRowTeach_drivesModelTeachBoss() async throws {
        let model = try makeVM(decisionLog: [openDecision()])
        try sheet(model, showFullLog: true).inspect()
            .find(button: "Do this automatically next time").tap()
        var appeared = false
        for _ in 0..<200 {
            if model.state.actionLog.contains(where: { $0.action == "teachBoss" }) { appeared = true; break }
            await Task.yield()
        }
        XCTAssertTrue(appeared,
                      "the full-log row's onTeach closure drove model.teachBoss:\n\(model.state.actionLog)")
    }

    // MARK: - L2328 / L2329 — onTeach (inbox row)

    func testInbox_teach_drivesModelTeachBoss() async throws {
        let model = try makeVM(decisionLog: [openDecision()])
        // The reinforce option ("Do this automatically next time") is not current for an `.escalate`
        // decision → a plain `Text` (findable); tapping it fires the inbox row's onTeach → teachBoss.
        // The closure dispatches via `Task { await … }`, so yield the MainActor until it lands.
        try sheet(model).inspect().find(button: "Do this automatically next time").tap()
        var appeared = false
        for _ in 0..<200 {
            if model.state.actionLog.contains(where: { $0.action == "teachBoss" }) { appeared = true; break }
            await Task.yield()
        }
        XCTAssertTrue(appeared,
                      "the inbox row's onTeach closure drove model.teachBoss:\n\(model.state.actionLog)")
    }
}
#endif
