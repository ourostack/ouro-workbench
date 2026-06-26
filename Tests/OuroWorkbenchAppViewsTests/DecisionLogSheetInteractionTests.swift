#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B6 — `DecisionLogSheet` (`:2168`) INTERACTION drive-to-100%.
///
/// The C4 `DecisionLogSheetTests` drove the empty/populated RENDER arms. This suite closes the
/// residual interaction + default-clock regions by INVOKING their closures:
///   - L2174/L2175  the prod-default `timeZone`/`locale` `.autoupdatingCurrent` autoclosure inits
///                  (every C4 test injected `.gmt`/`en_GB`, bypassing the defaults).
///   - L2188  `Button("Done") { dismiss() }` — tapped (the action body executes; `dismiss()` is the
///            environment no-op in a non-hosted inspect, so the assertion is that the tap runs the
///            region without mutating model state).
///   - L2214/L2215  the embedded `DecisionLogRow`'s `onTeach` trailing closure
///                  (`{ autoAdvance in Task { await model.teachBoss(...) } }`) — reached by tapping
///                  the row's Teach Menu inside the sheet; the side-effect is the synchronous
///                  `recordActionLog("teachBoss", …)` entry `teachBoss` posts before its `await`.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` store seam (AN-001); the decision log is
/// persisted through `WorkbenchStore.save` and decoded back through the real load path.
@MainActor
final class DecisionLogSheetInteractionTests: XCTestCase {

    private static let fixedDate = Date(timeIntervalSince1970: 1_767_323_045)
    private static let clockLocale = Locale(identifier: "en_GB")
    private static let decisionId = UUID(uuidString: "DEC15102-0000-0000-0000-00000000001B")!

    private func makeVM(decisionLog: [BossInboxDecision]) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b6-logsheet-\(UUID().uuidString)", isDirectory: true)
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

    private func decision() -> BossInboxDecision {
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

    // MARK: - L2174 / L2175 — prod-default clock autoclosures

    func testLogSheet_prodDefaultClock_constructsDeterministically() throws {
        let model = try makeVM(decisionLog: [decision()])
        let sheet = DecisionLogSheet(model: model)  // timeZone/locale default to .autoupdatingCurrent
        let a = try ViewSnapshotHost.snapshotText(of: sheet)
        let b = try ViewSnapshotHost.snapshotText(of: sheet)
        XCTAssertEqual(a, b, "the prod-default-clock sheet renders byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
        XCTAssertTrue(a.contains("deploy-runner"), "the row renders under the prod defaults")
    }

    // MARK: - L2188 — the Done button action

    func testLogSheet_doneButton_tapRunsWithoutMutatingModel() throws {
        let model = try makeVM(decisionLog: [decision()])
        let beforeLog = model.state.decisionLog
        let sheet = DecisionLogSheet(model: model, timeZone: .gmt, locale: Self.clockLocale)
        // The Done button's action is `dismiss()` — an environment no-op under inspect, but the
        // closure region executes. Assert it taps cleanly and leaves the model untouched.
        try sheet.inspect().find(button: "Done").tap()
        XCTAssertEqual(model.state.decisionLog, beforeLog,
                       "tapping Done runs the dismiss closure without mutating the decision log")
    }

    // MARK: - L2214 / L2215 — the embedded row's onTeach trailing closure

    func testLogSheet_embeddedRowTeach_firesTeachBossViaModel() async throws {
        let model = try makeVM(decisionLog: [decision()])
        XCTAssertTrue(model.state.actionLog.isEmpty, "provenance: no action-log entries before teach")
        let sheet = DecisionLogSheet(model: model, timeZone: .gmt, locale: Self.clockLocale)

        // Tap the embedded row's Teach Menu item. The sheet's trailing closure
        // `{ autoAdvance in Task { await model.teachBoss(...) } }` fires, scheduling the async
        // `teachBoss` (which records a "teachBoss" action-log entry). For an `.escalate` decision the
        // reinforce option ("Do this automatically next time") is NOT current → a plain `Text`
        // (findable by title); the current option renders a `Label("… (current)")` instead.
        try sheet.inspect().find(button: "Do this automatically next time").tap()

        // The closure dispatches the entry via `Task { await … }`; yield the MainActor until it lands.
        let appeared = await Self.waitForTeachEntry(model)
        XCTAssertTrue(appeared,
                      "the embedded row's onTeach closure drove model.teachBoss (action-log entry):\n\(model.state.actionLog)")
    }

    // MARK: - Negative control (P2) — the teach closure is wired to the real model

    /// Without tapping, no teachBoss entry exists; tapping creates exactly one — proving the
    /// embedded-row closure (not a constant) drives the model.
    func testLogSheet_negativeControl_teachEntryAppearsOnlyOnTap() async throws {
        let model = try makeVM(decisionLog: [decision()])
        let sheet = DecisionLogSheet(model: model, timeZone: .gmt, locale: Self.clockLocale)
        XCTAssertFalse(model.state.actionLog.contains { $0.action == "teachBoss" },
                       "before tap: no teachBoss entry")
        try sheet.inspect().find(button: "Do this automatically next time").tap()
        _ = await Self.waitForTeachEntry(model)
        XCTAssertEqual(model.state.actionLog.filter { $0.action == "teachBoss" }.count, 1,
                       "exactly one teachBoss entry after one tap")
    }

    /// Yield the MainActor until the async `Task { await model.teachBoss(…) }` records its entry
    /// (bounded). Returns whether the entry appeared. `teachBoss` may `await` an MCP call that fails
    /// fast in the hermetic VM; the FIRST line it runs is the synchronous "teachBoss" record, so a
    /// few yields suffice.
    static func waitForTeachEntry(_ model: WorkbenchViewModel) async -> Bool {
        for _ in 0..<200 {
            if model.state.actionLog.contains(where: { $0.action == "teachBoss" }) { return true }
            await Task.yield()
        }
        return model.state.actionLog.contains { $0.action == "teachBoss" }
    }
}
#endif
