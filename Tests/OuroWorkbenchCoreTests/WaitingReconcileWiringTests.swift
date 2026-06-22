import XCTest
@testable import OuroWorkbenchCore

/// F12a Gap 3b — durable wiring assertions for the un-triaged-waiting reconciler.
///
/// The pure `WaitingSessionReconciler.untriagedWaitingEntryIds` is unit-tested + 100%
/// covered in Core; the App that wires it isn't coverage-gated, so we source-pin its
/// structure the `appSource()` way.
///
/// The risks these pins defend:
///   - the reconcile helper must consult the pure reconciler seam against the LIVE
///     entries + the open inbox, and synthesize an escalate decision per uncovered
///     waiting id via `recordDecisionIfNew` — the prompt+kind dedup that keeps a
///     still-waiting session from re-flooding the inbox every tick;
///   - it must be invoked AFTER recordBossDecisions (so a fresh decision the boss
///     just made covers its session first) AND on startup after load (so a session
///     that was waiting across a restart with no decision is triaged);
///   - the synthesized decision must be an `.escalate` (surfaced to the human, not
///     acted on).
final class WaitingReconcileWiringTests: XCTestCase {
    func testReconcileHelperConsultsTheSeamAndRecordsViaRecordDecisionIfNew() throws {
        let body = try reconcileHelper()
        XCTAssertTrue(
            body.contains("WaitingSessionReconciler.untriagedWaitingEntryIds("),
            "the reconcile helper must consult the pure WaitingSessionReconciler seam"
        )
        XCTAssertTrue(
            body.contains("openInbox(") || body.contains("state.openInbox"),
            "the helper must pass the live open inbox so already-triaged sessions are excluded"
        )
        XCTAssertTrue(
            body.contains("recordDecisionIfNew("),
            "each uncovered waiting id must be synthesized via recordDecisionIfNew (prompt+kind dedup — no inbox flooding)"
        )
        XCTAssertTrue(
            body.contains(".escalate"),
            "the synthesized decision must be an escalate (surfaced to the human, not auto-acted)"
        )
    }

    func testReconcileSavesOnlyWhenSomethingChanged() throws {
        let body = try reconcileHelper()
        // recordDecisionIfNew returns whether it recorded; the helper must only
        // save() when at least one was added, so a steady-state tick (everything
        // already triaged) doesn't churn the disk.
        XCTAssertTrue(
            body.contains("save()"),
            "the helper must persist newly-synthesized decisions"
        )
        let recordIndex = try XCTUnwrap(body.range(of: "recordDecisionIfNew(")?.lowerBound)
        let saveIndex = try XCTUnwrap(body.range(of: "save()")?.lowerBound)
        XCTAssertLessThan(recordIndex, saveIndex, "save must follow the record loop")
    }

    func testReconcileIsInvokedAfterRecordBossDecisions() throws {
        let source = try appSource()
        // In the check-in success path: recordBossDecisions(from: answer) then the
        // reconcile, so a just-made decision covers its own session first.
        let recordDecisionsIndex = try XCTUnwrap(
            source.range(of: "recordBossDecisions(from: answer)")?.lowerBound,
            "the check-in must record boss decisions"
        )
        let reconcileIndex = try XCTUnwrap(
            source.range(of: "reconcileWaitingSessionsIntoInbox(", range: recordDecisionsIndex..<source.endIndex)?.lowerBound,
            "the reconcile must run AFTER recordBossDecisions on the check-in path"
        )
        XCTAssertGreaterThan(reconcileIndex, recordDecisionsIndex)
    }

    func testReconcileIsInvokedAtStartup() throws {
        let source = try appSource()
        // The startup task wires the reconcile so a session waiting across a restart
        // (no decision) is triaged. Pin it sits in the startup sequence alongside
        // the other startup reconciles.
        let startup = try sourceSlice(
            in: source,
            from: "model.reconcileStartupAttentionWithLiveSessions()",
            to: "model.refreshOnboardingReadiness()"
        )
        XCTAssertTrue(
            startup.contains("reconcileWaitingSessionsIntoInbox("),
            "the reconcile must be invoked at startup so a session waiting across a restart with no decision is triaged"
        )
    }

    // MARK: - Helpers

    private func reconcileHelper() throws -> String {
        try sourceSlice(
            in: try appSource(),
            from: "func reconcileWaitingSessionsIntoInbox(",
            to: "\n    func "
        )
    }

    private func appSource() throws -> String {
        let sourceURL = repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("OuroWorkbenchApp")
            .appendingPathComponent("OuroWorkbenchApp.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceSlice(in source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound, "missing start marker: \(startMarker)")
        let end = try XCTUnwrap(source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound, "missing end marker: \(endMarker)")
        return String(source[start..<end])
    }
}
