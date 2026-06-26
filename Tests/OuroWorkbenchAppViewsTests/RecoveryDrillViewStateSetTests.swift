#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C10-5 — the recovery-drill harness (`RecoveryDrillView` `:10422`). Runs a simulated startup
/// reconcile and lists what each session WOULD do on a real restart.
///
/// **Provenance (P2).** The drill result is produced by the REAL pure Core producer
/// `RecoveryDrill().run(state:now:)` — fed a real `WorkspaceState` (a `.needsRecovery` run) +
/// a FIXED `now` — and assigned to `model.recoveryDrillResult` (the SAME `@Published` the
/// production `runRecoveryDrill()` sets — direct injection IS the real seam). The per-row sentence
/// flows through the REAL `RecoveryReasonPhrasebook.operatorSentence`. NO hand-assembled result.
///
/// **Clock migration (AN-007 — the C10 named hazard).** The status line at `:12068` was a raw
/// `recoveryDrillResult.ranAt.formatted(date:.omitted, time:.standard)`. It is MIGRATED: the model
/// accessor became `recoveryDrillStatusLine(timeZone:locale:)` rendering through
/// `Date.workbenchTimeText` (prod default `.autoupdatingCurrent` → byte-identical), and the view
/// gained injectable `timeZone`/`locale` it passes through. The test injects `.gmt` + `en_GB` for
/// a runner-zone/locale-independent timestamp; the cross-TZ proof is the dedicated test below.
///
/// **Path-safety (P3).** The visible row renders the group/entry label + the phrasebook sentence;
/// the raw action/status/reason audit lives ONLY in the `.help()` tooltip (host-dropped). A fixed
/// `/tmp/u4` working dir + `!tree.contains('/Users/')` defend it.
///
/// **Enumerated state-set:**
///   - `notRun`     — `recoveryDrillResult == nil` → the "not run" status line, no rows.
///   - `withResult` — a real drill result → the `oneLineStatus; <fixed timestamp>` line + the
///                    `ForEach(items.prefix(5))` rows.
@MainActor
final class RecoveryDrillViewStateSetTests: XCTestCase {

    /// 2026-01-02 03:04:05 UTC → `3:04:05` under `.gmt`/`en_GB` (the C4 stable clock locale).
    private static let fixedNow = Date(timeIntervalSince1970: 1_767_323_045)
    private static let clockLocale = Locale(identifier: "en_GB")
    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
    private static let entryId = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
    private static let runId = UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000A1")!
    private static let started = Date(timeIntervalSince1970: 1_767_322_000)

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c10drill-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    /// A real `WorkspaceState` whose latest run `.needsRecovery` → the drill produces a recovery
    /// item for it (the genuine producer path).
    private func recoverableState() -> WorkspaceState {
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: [WorkbenchProject(id: Self.projectId, name: "alpha", rootPath: "/tmp/u4")],
            processEntries: [ProcessEntry(id: Self.entryId, projectId: Self.projectId, name: "deploy-runner",
                                          kind: .shell, executable: "/bin/zsh", workingDirectory: "/tmp/u4",
                                          autoResume: true)],
            processRuns: [ProcessRun(id: Self.runId, entryId: Self.entryId, status: .needsRecovery,
                                     startedAt: Self.started)]
        )
    }

    /// `notRun` (no result assigned) view.
    private func notRunView() throws -> RecoveryDrillView {
        RecoveryDrillView(model: try makeVM(), timeZone: .gmt, locale: Self.clockLocale)
    }

    /// `withResult` view — the real producer feeds `recoveryDrillResult` with a FIXED `now`.
    private func withResultView() throws -> (RecoveryDrillView, RecoveryDrillResult) {
        let model = try makeVM()
        model.state = recoverableState()
        let result = RecoveryDrill().run(state: recoverableState(), now: Self.fixedNow)
        model.recoveryDrillResult = result
        return (RecoveryDrillView(model: model, timeZone: .gmt, locale: Self.clockLocale), result)
    }

    // MARK: - Enumerated state-set

    /// NOT RUN — no result → the "not run" status line, no rows.
    func testDrill_notRun() throws {
        let view = try notRunView()
        XCTAssertNil(view.model.recoveryDrillResult, "provenance: no drill run yet")
        XCTAssertEqual(view.model.recoveryDrillStatusLine(timeZone: .gmt, locale: Self.clockLocale),
                       "not run", "provenance: nil result → 'not run'")
        try assertViewSnapshot(of: view, named: "RecoveryDrillView.notRun")
    }

    /// WITH RESULT — the real drill produced a result + at least one item → the status line (with
    /// the FIXED `.gmt` timestamp) + the item rows render.
    func testDrill_withResult() throws {
        let (view, result) = try withResultView()
        XCTAssertEqual(result.ranAt, Self.fixedNow, "provenance: the fixed ranAt timestamp")
        XCTAssertFalse(result.items.isEmpty, "provenance: the recoverable run produced a drill item")
        XCTAssertEqual(view.model.groupName(forEntryId: Self.entryId), "alpha",
                       "provenance: the group label resolves through the real state")
        try assertViewSnapshot(of: view, named: "RecoveryDrillView.withResult")
    }

    // MARK: - Path-leak defense (P3)

    func testDrill_pathLeakDefense_noMachinePathInTree() throws {
        let (view, _) = try withResultView()
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertFalse(tree.contains("/Users/"), "no /Users/ machine-path leak:\n\(tree)")
        XCTAssertFalse(tree.contains("/var/folders/"), "no temp-dir path leak:\n\(tree)")
    }

    // MARK: - Clock determinism (P3 — AN-007)

    func testDrill_clockDeterminism_byteIdenticalTwiceAndFixedTimestamp() throws {
        let (a, _) = try withResultView()
        let (b, _) = try withResultView()
        let ta = try ViewSnapshotHost.snapshotText(of: a)
        let tb = try ViewSnapshotHost.snapshotText(of: b)
        XCTAssertEqual(ta, tb, "the fixed-timestamp drill must serialize byte-identically twice")
        XCTAssertFalse(ta.contains("/Users/"), "no machine-path leak:\n\(ta)")
        XCTAssertTrue(ta.contains("3:04:05"),
                      "the migrated seam renders the fixed ranAt as a stable .gmt/en_GB clock:\n\(ta)")
    }

    /// Cross-TZ PROOF (AN-007): the `.gmt`/`en_GB`-injected status-line timestamp is byte-identical
    /// across {PDT, EDT, UTC} process zones.
    func testDrill_crossTimeZone_byteIdenticalAcrossPDTEDTUTC() throws {
        let original = ProcessInfo.processInfo.environment["TZ"]
        defer {
            if let original { setenv("TZ", original, 1) } else { unsetenv("TZ") }
            tzset(); NSTimeZone.resetSystemTimeZone()
        }
        var trees: [String] = []
        for tz in ["America/Los_Angeles", "America/New_York", "UTC"] {
            setenv("TZ", tz, 1); tzset(); NSTimeZone.resetSystemTimeZone()
            let (view, _) = try withResultView()
            trees.append(try ViewSnapshotHost.snapshotText(of: view))
        }
        XCTAssertEqual(Set(trees).count, 1,
                       "the .gmt/en_GB-injected drill timestamp must be byte-identical across PDT/EDT/UTC")
        XCTAssertTrue(trees[0].contains("3:04:05"), "and renders the fixed .gmt clock:\n\(trees[0])")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// A drill result flips the tree: the status line changes from "not run" to the
    /// "N recovery action(s)…; <timestamp>" line and the item rows appear — a real
    /// `recoveryDrillResult`-driven branch.
    func testDrill_negativeControl_resultFlipsTree() throws {
        let notRun = try ViewSnapshotHost.snapshotText(of: try notRunView())
        let (withResultView, _) = try withResultView()
        let withResult = try ViewSnapshotHost.snapshotText(of: withResultView)

        XCTAssertNotEqual(notRun, withResult, "a drill result must flip the tree")
        XCTAssertTrue(notRun.contains("not run"), "not-run: the 'not run' status line:\n\(notRun)")
        XCTAssertTrue(withResult.contains("recovery action"),
                      "with-result: the oneLineStatus renders:\n\(withResult)")
        XCTAssertTrue(withResult.contains("deploy-runner"), "with-result: the item row renders")
        XCTAssertFalse(withResult.contains("not run"), "with-result: not the empty status line")
    }
}
#endif
