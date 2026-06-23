import XCTest
@testable import OuroWorkbenchCore

/// U21: the always-visible Boss Watch on/off read and the compact action-receipt
/// summary the default boss pane surfaces. Both are pure derivations so the
/// header pill, the popover, and the dashboard all agree without re-deriving the
/// label or recounting the log per surface.
final class BossWatchPresentationTests: XCTestCase {

    // MARK: - On/off label

    func testEnabledReadsAsOn() {
        let p = BossWatchPresentation.resolve(isEnabled: true)
        XCTAssertTrue(p.isOn)
        XCTAssertEqual(p.label, "On")
        XCTAssertEqual(p.shortLabel, "Watch On")
    }

    func testDisabledReadsAsOff() {
        let p = BossWatchPresentation.resolve(isEnabled: false)
        XCTAssertFalse(p.isOn)
        XCTAssertEqual(p.label, "Off")
        XCTAssertEqual(p.shortLabel, "Watch Off")
    }

    func testToggleActionTitleFlipsWithState() {
        XCTAssertEqual(BossWatchPresentation.resolve(isEnabled: true).toggleActionTitle, "Pause Boss Watch")
        XCTAssertEqual(BossWatchPresentation.resolve(isEnabled: false).toggleActionTitle, "Start Boss Watch")
    }

    func testHelpExplainsWhatAutonomyMeans() {
        XCTAssertTrue(BossWatchPresentation.resolve(isEnabled: true).help.contains("acting"))
        XCTAssertTrue(BossWatchPresentation.resolve(isEnabled: false).help.lowercased().contains("paused"))
    }

    // MARK: - U31(a): no Boss Watch pill before a usable boss exists

    func testHiddenWhenNoUsableBoss() {
        // Boss Watch watches *via* a boss; with no usable boss there's nothing to
        // watch with, so the header pill must not render — it can't be "on", and a
        // green "Watch On" on a no-boss first run is incoherent (breaks the U5 calm
        // no-boss header). The on/off state is irrelevant when there's no boss.
        let off = BossWatchPresentation.resolve(isEnabled: false, hasUsableBoss: false)
        XCTAssertFalse(off.isVisible)
        let on = BossWatchPresentation.resolve(isEnabled: true, hasUsableBoss: false)
        XCTAssertFalse(on.isVisible, "even if the stored flag is on, no usable boss ⇒ pill hidden")
    }

    func testVisibleAndOnOffWhenUsableBossExists() {
        let on = BossWatchPresentation.resolve(isEnabled: true, hasUsableBoss: true)
        XCTAssertTrue(on.isVisible)
        XCTAssertTrue(on.isOn)
        XCTAssertEqual(on.shortLabel, "Watch On")
        let off = BossWatchPresentation.resolve(isEnabled: false, hasUsableBoss: true)
        XCTAssertTrue(off.isVisible)
        XCTAssertFalse(off.isOn)
        XCTAssertEqual(off.shortLabel, "Watch Off")
    }

    func testDefaultsToVisibleSoExistingCallersUnchanged() {
        // The hasUsableBoss parameter defaults to true: callers that pre-date U31(a)
        // (and the popover/dashboard controls, which only render with a boss set)
        // keep their on/off behavior untouched.
        XCTAssertTrue(BossWatchPresentation.resolve(isEnabled: true).isVisible)
        XCTAssertTrue(BossWatchPresentation.resolve(isEnabled: false).isVisible)
    }

    // MARK: - Action-receipt summary

    private func action(_ ok: Bool, action: String = "recover", at: TimeInterval = 0) -> WorkbenchActionLogEntry {
        WorkbenchActionLogEntry(
            occurredAt: Date(timeIntervalSince1970: at),
            source: "boss:slugger",
            action: action,
            result: ok ? "applied" : "failed",
            succeeded: ok
        )
    }

    /// An in-flight optimistic ack: `succeeded: true` (the "Working on…" copy passes
    /// the prefix check) but `isInFlight: true` — it has NOT settled yet.
    private func inFlightAction(action: String = "connect", at: TimeInterval = 0) -> WorkbenchActionLogEntry {
        WorkbenchActionLogEntry(
            occurredAt: Date(timeIntervalSince1970: at),
            source: "boss:slugger",
            action: action,
            result: "Working on it…",
            succeeded: true,
            isInFlight: true
        )
    }

    func testReceiptSummaryCountsOkAndFailed() {
        let entries = [action(true), action(true), action(false), action(true)]
        let s = BossActionReceiptSummary.summarize(entries)
        XCTAssertEqual(s.okCount, 3)
        XCTAssertEqual(s.failedCount, 1)
        XCTAssertEqual(s.totalCount, 4)
        XCTAssertTrue(s.hasFailures)
        XCTAssertFalse(s.isEmpty)
    }

    func testReceiptSummaryLabelReadsAsCounts() {
        let entries = [action(true), action(true), action(true), action(false)]
        XCTAssertEqual(BossActionReceiptSummary.summarize(entries).label, "3 ok · 1 failed")
    }

    func testReceiptSummaryLabelDropsFailedSegmentWhenNoneFailed() {
        let entries = [action(true), action(true)]
        let s = BossActionReceiptSummary.summarize(entries)
        XCTAssertEqual(s.label, "2 ok")
        XCTAssertFalse(s.hasFailures)
    }

    func testReceiptSummaryEmptyLogReadsAsNoActions() {
        let s = BossActionReceiptSummary.summarize([])
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.okCount, 0)
        XCTAssertEqual(s.failedCount, 0)
        XCTAssertEqual(s.label, "No actions yet")
        XCTAssertFalse(s.hasFailures)
    }

    func testReceiptSummaryHonorsWindowNewestFirst() {
        // 5 entries, window of 3 → only the 3 newest are counted.
        let entries = [
            action(false, at: 50),
            action(true, at: 40),
            action(true, at: 30),
            action(false, at: 20),
            action(false, at: 10)
        ]
        let s = BossActionReceiptSummary.summarize(entries, window: 3)
        XCTAssertEqual(s.totalCount, 3)
        XCTAssertEqual(s.okCount, 2)
        XCTAssertEqual(s.failedCount, 1, "only the newest 3 (one failed) count, not the older 2 failures")
    }

    func testReceiptSummaryWindowDefaultIsWholeLog() {
        let entries = (0..<10).map { action($0 % 2 == 0, at: TimeInterval($0)) }
        let s = BossActionReceiptSummary.summarize(entries)
        XCTAssertEqual(s.totalCount, 10)
    }

    func testReceiptSummaryFailedFirstReceiptsSurfaceFailures() {
        // The most-recent failed entries are exposed so the pane can show the
        // failures prominently without the caller re-scanning the log.
        let entries = [
            action(true, action: "sendInput", at: 50),
            action(false, action: "recover", at: 40),
            action(true, action: "recover", at: 30),
            action(false, action: "sendInput", at: 20)
        ]
        let s = BossActionReceiptSummary.summarize(entries)
        XCTAssertEqual(s.failedReceipts.map(\.action), ["recover", "sendInput"], "failures newest-first, successes excluded")
    }

    // MARK: - In-flight acks must NOT inflate okCount (false-success at the count level)

    func testInFlightAckDoesNotInflateOkCount() {
        // An in-flight ack has succeeded == true, but it has NOT settled — it must
        // count as neither ok nor failed. Excluding it from the denominator (not
        // pushing it into the ok bucket) is the whole point.
        let s = BossActionReceiptSummary.summarize([inFlightAction()])
        XCTAssertEqual(s.okCount, 0, "an in-flight ack is not a verified success — it must not count as ok")
        XCTAssertEqual(s.failedCount, 0, "an in-flight ack is not a failure either")
        XCTAssertEqual(s.totalCount, 0, "in-flight is excluded from both buckets, so the total is empty")
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.label, "No actions yet", "a log of only in-flight acks reports nothing settled yet")
    }

    func testSettledSuccessStillCountsAsOk() {
        // The honesty invariant's positive direction: a settled (!isInFlight)
        // succeeded entry still counts as ok.
        let s = BossActionReceiptSummary.summarize([action(true)])
        XCTAssertEqual(s.okCount, 1)
        XCTAssertEqual(s.failedCount, 0)
    }

    func testSettledFailureStillCountsAsFailed() {
        // The honesty invariant's failure direction: a settled failure must NOT be
        // swallowed by the pending exclusion — it still counts as failed.
        let s = BossActionReceiptSummary.summarize([action(false)])
        XCTAssertEqual(s.okCount, 0)
        XCTAssertEqual(s.failedCount, 1)
        XCTAssertEqual(s.failedReceipts.count, 1)
    }

    func testInFlightExcludedFromBothBucketsAlongsideSettledEntries() {
        // A mixed log: one settled success, one settled failure, one in-flight ack.
        // The in-flight ack is excluded from BOTH buckets; only the two settled
        // entries are counted.
        let entries = [
            action(true, at: 30),
            inFlightAction(at: 20),
            action(false, at: 10)
        ]
        let s = BossActionReceiptSummary.summarize(entries)
        XCTAssertEqual(s.okCount, 1, "only the settled success counts as ok; the in-flight ack does not")
        XCTAssertEqual(s.failedCount, 1, "only the settled failure counts as failed")
        XCTAssertEqual(s.totalCount, 2, "the in-flight ack is in neither bucket")
        XCTAssertEqual(s.failedReceipts.map(\.action), ["recover"], "only the settled failure is a failed receipt")
        XCTAssertEqual(s.label, "1 ok · 1 failed")
    }

    func testInFlightExcludedWithinWindow() {
        // The window is applied first (newest-first), then in-flight is excluded —
        // an in-flight ack inside the window still doesn't inflate okCount.
        let entries = [
            inFlightAction(at: 50),
            action(true, at: 40),
            action(false, at: 30),
            action(true, at: 20),
            action(true, at: 10)
        ]
        let s = BossActionReceiptSummary.summarize(entries, window: 3)
        // Newest 3 = [in-flight@50, ok@40, failed@30] → settled = 1 ok + 1 failed.
        XCTAssertEqual(s.okCount, 1)
        XCTAssertEqual(s.failedCount, 1)
        XCTAssertEqual(s.totalCount, 2, "the in-flight ack inside the window is excluded from both buckets")
    }
}
