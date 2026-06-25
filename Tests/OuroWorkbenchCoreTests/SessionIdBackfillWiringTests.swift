import XCTest
@testable import OuroWorkbenchCore

/// F4 — durable wiring assertions for the session-id back-fill App pass. The pure
/// `SessionIdBackfill` seam is unit-tested + 100% covered in Core; the App that
/// invokes it isn't coverage-gated and can't be click-tested in CI, so we pin its
/// structural wiring the same way `ColdStartHonestWiringTests` (F1) does:
///
///   - a dedicated back-fill method exists and calls `SessionIdBackfill.sessionIdBackfills`;
///   - it applies each write GUARDED by `== nil` (no-clobber), then `save()`s;
///   - it runs a real `AgentSessionScanner().backfillRecords(state:processLister:)`
///     against the App's `ps`-backed lister — the UN-MERGED source, NOT the
///     display `scan` whose `harness|cwd` merge collapses all same-harness live
///     pids (the App's `ps` lister reports no cwd) and silently breaks multi-agent
///     recovery;
///   - it is wired into the post-output-settle point (alongside the attention
///     reclassify) — the moment the agent has had time to write its session file;
///   - `markStarted` STAYS AS-IS (it provably can't know the id yet) — it must NOT
///     start calling the back-fill seam.
final class SessionIdBackfillWiringTests: XCTestCase {
    func testBackfillMethodExistsAndCallsTheSeam() throws {
        let source = try WorkbenchAppSource.appSource()
        XCTAssertTrue(
            source.contains("func backfillSessionIdsForFlushedRuns"),
            "a dedicated back-fill pass method must exist"
        )
        let body = try backfillMethod()
        XCTAssertTrue(
            body.contains("SessionIdBackfill.sessionIdBackfills"),
            "the back-fill pass must call the pure SessionIdBackfill seam"
        )
    }

    func testBackfillRunsTheScannerAgainstTheInjectedLister() throws {
        let body = try backfillMethod()
        XCTAssertTrue(
            body.contains("AgentSessionScanner()"),
            "the back-fill pass must run a real AgentSessionScanner"
        )
        XCTAssertTrue(
            body.contains(".backfillRecords(") && body.contains("state:") && body.contains("processLister:"),
            "the scan must use the UN-MERGED backfillRecords source (NOT the display scan, whose harness|cwd merge collapses all same-harness live pids) and pass the workspace state + the ps-backed processLister"
        )
        XCTAssertFalse(
            body.contains(".scan("),
            "the back-fill pass must NOT use the display `scan` — its merge collapses same-harness running records to one survivor, dropping live pids from the seam's pin set and breaking multi-agent recovery"
        )
    }

    func testBackfillAppliesGuardedByNilThenSaves() throws {
        let body = try backfillMethod()
        // No-clobber: the write must be guarded by an `== nil` check on the run's
        // existing terminalSessionId.
        XCTAssertTrue(
            body.contains("terminalSessionId == nil"),
            "the write must be guarded by `terminalSessionId == nil` so a non-empty id is never clobbered"
        )
        XCTAssertTrue(
            body.contains(".terminalSessionId =") || body.contains("terminalSessionId = sessionId"),
            "the pass must assign the back-filled sessionId onto the run"
        )
        XCTAssertTrue(
            body.contains("save()"),
            "the pass must persist the back-filled ids via save()"
        )
    }

    func testBackfillIsWiredAtTheOutputSettlePoint() throws {
        let source = try WorkbenchAppSource.appSource()
        let reclassify = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "private func reclassifyAttentionForFlushedRuns",
            to: "\n    nonisolated private static func classifyTranscriptTail"
        )
        XCTAssertTrue(
            reclassify.contains("backfillSessionIdsForFlushedRuns"),
            "the back-fill pass must be triggered at the post-output-settle point (alongside reclassify)"
        )
    }

    func testMarkStartedDoesNotBackfill() throws {
        let source = try WorkbenchAppSource.appSource()
        let markStarted = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "func markStarted(plan: TerminalCommandPlan",
            to: "\n    /// Record that a run produced output."
        )
        // The id provably doesn't exist at markStarted; it must NOT try to back-fill.
        XCTAssertFalse(
            markStarted.contains("SessionIdBackfill"),
            "markStarted must stay as-is — the native id doesn't exist yet at start"
        )
        XCTAssertFalse(
            markStarted.contains("backfillSessionIdsForFlushedRuns"),
            "markStarted must not invoke the back-fill pass"
        )
    }

    // MARK: - Helpers (mirror ColdStartHonestWiringTests)

    /// The whole F4 back-fill block: `backfillSessionIdsForFlushedRuns` through the
    /// `ps`-backed lister, up to the unrelated `classifyTranscriptTail` helper.
    private func backfillMethod() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "private func backfillSessionIdsForFlushedRuns",
            to: "nonisolated private static func classifyTranscriptTail"
        )
    }
}
