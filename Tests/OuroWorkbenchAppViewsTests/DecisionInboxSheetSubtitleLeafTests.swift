#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// AN-R3-04 — energy-0 round-3 close for the `default` (count ≥ 2) arm of `DecisionInboxSheet`'s
/// `inboxSubtitle(_:)` (`:2297`).
///
/// The inbox header subtitle is a three-arm count switch over `openCount` (total OPEN decisions
/// across the severity groups):
///
///   - case 0  → "Nothing needs you right now"        — pinned (DecisionInboxSheet.zeroNoLog/zeroWithLog)
///   - case 1  → "1 session needs a decision"         — pinned (DecisionInboxSheet.queue)
///   - default → "\(count) sessions need a decision"  ← UNCONTROLLED (residual P2 energy)
///
/// The round-3 single-actor serial mutation sweep proved the `default` arm was residual energy:
/// mutating its string left the FULL app-views suite GREEN. Every committed inbox fixture has
/// exactly zero or one OPEN decision (`testInbox_zero*` → 0; `testInbox_queue` → 1), so a 2+-decision
/// inbox — the everyday "several sessions are waiting on you" state — never rendered, and its
/// plural subtitle was unasserted. The `case 0` and `case 1` arms went RED under the same sweep
/// (caught in the committed snapshots), so this leaf closes the one live gap.
///
/// **Provenance (P2).** Two distinct OPEN `.escalate` `BossInboxDecision`s (distinct ids + sessions,
/// each `needsHuman` with no triage → open at any `now`) are saved through the real
/// `WorkbenchStore.save` seam; the sheet derives `openCount` from the live
/// `WorkspaceState.openInboxGroups(now:)` — the same producer the live sheet uses. The test asserts
/// `openCount == 2` through that producer BEFORE asserting the rendered subtitle, so the count-2
/// state is producer-derived, not hand-set.
///
/// **Determinism (P3).** Fixed `now` / `occurredAt` (UTC) + a pinned `timeZone`/`locale` on the
/// sheet — the same dual-clock discipline the sibling inbox tests use. Byte-identical twice + no
/// machine-path leak below.
@MainActor
final class DecisionInboxSheetSubtitleLeafTests: XCTestCase {

    private static let fixedNow = Date(timeIntervalSince1970: 1_767_355_200)   // 2026-01-02 12:00:00 UTC
    private static let fixedDate = Date(timeIntervalSince1970: 1_767_323_045)  // before fixedNow
    private static let clockLocale = Locale(identifier: "en_GB")
    private static let decisionA = UUID(uuidString: "DEC15102-0000-0000-0000-0000000000A1")!
    private static let decisionB = UUID(uuidString: "DEC15102-0000-0000-0000-0000000000B2")!

    private func makeVM(decisionLog: [BossInboxDecision]) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anr3-inbox-\(UUID().uuidString)", isDirectory: true)
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

    /// One OPEN escalate decision (needsHuman + no triage → open at any `now`).
    private func openDecision(id: UUID, session: String, friend: String) -> BossInboxDecision {
        BossInboxDecision(
            id: id,
            occurredAt: Self.fixedDate,
            source: "boss:slugger",
            sessionName: session,
            friendName: friend,
            prompt: "Apply the migration?",
            kind: .escalate,
            proposedInput: "y",
            preferenceCited: "\(friend) always approves staging migrations",
            confidence: 0.82,
            reasoning: "Matches the team's standing preference.",
            status: .recorded
        )
    }

    private func sheet(_ model: WorkbenchViewModel) -> DecisionInboxSheet {
        DecisionInboxSheet(model: model, now: Self.fixedNow, timeZone: .gmt, locale: Self.clockLocale)
    }

    private func twoOpenDecisions() -> [BossInboxDecision] {
        [openDecision(id: Self.decisionA, session: "deploy-runner", friend: "Sam"),
         openDecision(id: Self.decisionB, session: "build-runner", friend: "Avery")]
    }

    // MARK: - The committed reference — two open decisions → the plural subtitle

    func testInbox_twoOpen_rendersPluralSubtitle() throws {
        let model = try makeVM(decisionLog: twoOpenDecisions())

        // Provenance: the REAL grouping producer yields a total open count of 2.
        let groups = model.state.openInboxGroups(now: Self.fixedNow)
        let openCount = groups.reduce(0) { $0 + $1.decisions.count }
        XCTAssertEqual(openCount, 2, "provenance: two open escalate decisions → openCount == 2")

        let tree = try ViewSnapshotHost.snapshotText(of: sheet(model))
        XCTAssertTrue(tree.contains(#"text="2 sessions need a decision""#),
                      "the default (count>=2) subtitle arm:\n\(tree)")
        try assertViewSnapshot(of: sheet(model), named: "DecisionInboxSheet.twoOpen")
    }

    // MARK: - Negative control (P2) — the count drives the subtitle (singular vs plural)

    /// Dropping to ONE open decision flips the subtitle to the singular `case 1` string and removes
    /// the plural — proving `openCount` (not a constant) governs the captured subtitle.
    func testInbox_negativeControl_oneOpenFlipsToSingular() throws {
        let two = try ViewSnapshotHost.snapshotText(of: sheet(try makeVM(decisionLog: twoOpenDecisions())))
        let one = try ViewSnapshotHost.snapshotText(of: sheet(try makeVM(
            decisionLog: [openDecision(id: Self.decisionA, session: "deploy-runner", friend: "Sam")])))

        XCTAssertTrue(two.contains(#"text="2 sessions need a decision""#), "two → plural:\n\(two)")
        XCTAssertFalse(two.contains(#"text="1 session needs a decision""#), "two is not singular:\n\(two)")

        XCTAssertTrue(one.contains(#"text="1 session needs a decision""#), "one → singular:\n\(one)")
        XCTAssertFalse(one.contains(#"text="2 sessions need a decision""#), "one is not plural:\n\(one)")

        XCTAssertNotEqual(two, one, "openCount flips the subtitle (plural vs singular)")
    }

    // MARK: - Determinism (P3)

    func testInbox_twoOpen_twiceRunByteIdentical_noLeak() throws {
        let model = try makeVM(decisionLog: twoOpenDecisions())
        let a = try ViewSnapshotHost.snapshotText(of: sheet(model))
        let b = try ViewSnapshotHost.snapshotText(of: sheet(model))
        XCTAssertEqual(a, b, "the two-open inbox must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
    }
}
#endif
