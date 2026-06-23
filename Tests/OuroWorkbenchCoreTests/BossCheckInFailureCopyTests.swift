import XCTest
@testable import OuroWorkbenchCore

/// FIX 2 (MED) — the manual Check In failure copy must not lie. With Boss Watch
/// OFF (the default), nothing retries a failed check-in: the only retry driver is
/// the automatic `runBossWatchLoop`, gated on `bossWatchIsEnabled`. So the old
/// copy ("Workbench will try again shortly" / "keeps trying, a little less often
/// each time") promised a retry that never came — the operator waited forever.
/// This pure seam selects honest copy as a function of (failureCount,
/// bossWatchIsEnabled): when watch is OFF it tells the operator to press Check In;
/// when ON it keeps the truthful "will try again" promise (the loop IS retrying).
final class BossCheckInFailureCopyTests: XCTestCase {

    // MARK: - Transient failure line (the bossCheckInAnswer after a failed ask)

    func testTransientLineDoesNotPromiseAutoRetryWhenWatchOff() {
        let line = BossCheckInFailureCopy.failureLine(failureCount: 1, bossWatchIsEnabled: false)
        // No false promise that *Workbench* will retry on its own.
        XCTAssertFalse(line.lowercased().contains("try again shortly"))
        XCTAssertFalse(line.lowercased().contains("keeps trying"))
        // Instead, it must tell the operator the actionable next step: press Check In.
        XCTAssertTrue(line.contains("Check In"), "watch-OFF copy must point at the Check In button")
    }

    func testTransientLineKeepsTheTruthfulAutoRetryPromiseWhenWatchOn() {
        let line = BossCheckInFailureCopy.failureLine(failureCount: 1, bossWatchIsEnabled: true)
        // When the watch loop IS running, "will try again" is TRUE — keep it.
        XCTAssertTrue(
            line.lowercased().contains("try again"),
            "watch-ON copy must keep the truthful auto-retry promise"
        )
    }

    func testTransientLineDiffersByWatchState() {
        let off = BossCheckInFailureCopy.failureLine(failureCount: 1, bossWatchIsEnabled: false)
        let on = BossCheckInFailureCopy.failureLine(failureCount: 1, bossWatchIsEnabled: true)
        XCTAssertNotEqual(off, on, "the copy must branch on bossWatchIsEnabled")
    }

    // MARK: - Persistent banner (shown after >= 2 consecutive failures)

    func testPersistentBannerBodyDoesNotPromiseAutoRetryWhenWatchOff() {
        let banner = BossCheckInFailureCopy.persistentBanner(failureCount: 3, bossWatchIsEnabled: false)
        let joined = (banner.title + " " + banner.detail + " " + banner.guidance).lowercased()
        XCTAssertFalse(joined.contains("still trying"))
        XCTAssertFalse(joined.contains("keeps trying"))
        XCTAssertFalse(joined.contains("a little less often"))
        XCTAssertTrue(banner.guidance.contains("Check In"), "watch-OFF banner must point at the Check In button")
    }

    func testPersistentBannerBodyKeepsAutoRetryCopyWhenWatchOn() {
        let banner = BossCheckInFailureCopy.persistentBanner(failureCount: 3, bossWatchIsEnabled: true)
        let joined = (banner.detail + " " + banner.guidance).lowercased()
        XCTAssertTrue(
            joined.contains("still trying") || joined.contains("keeps trying"),
            "watch-ON banner must keep the truthful auto-retry copy"
        )
    }

    func testPersistentBannerInterpolatesTheFailureCount() {
        let banner = BossCheckInFailureCopy.persistentBanner(failureCount: 4, bossWatchIsEnabled: true)
        XCTAssertTrue(
            banner.detail.contains("4"),
            "the banner detail must report how many times the agent failed to answer"
        )
    }

    func testPersistentBannerDiffersByWatchState() {
        let off = BossCheckInFailureCopy.persistentBanner(failureCount: 3, bossWatchIsEnabled: false)
        let on = BossCheckInFailureCopy.persistentBanner(failureCount: 3, bossWatchIsEnabled: true)
        XCTAssertNotEqual(off.guidance, on.guidance, "the banner guidance must branch on bossWatchIsEnabled")
    }

    func testPersistentBannerTitleIsStableAcrossWatchState() {
        // The headline ("Your agent isn't answering yet") is the same regardless of
        // watch state — only the retry promise changes — so the surface reads
        // consistently.
        let off = BossCheckInFailureCopy.persistentBanner(failureCount: 3, bossWatchIsEnabled: false)
        let on = BossCheckInFailureCopy.persistentBanner(failureCount: 3, bossWatchIsEnabled: true)
        XCTAssertEqual(off.title, on.title)
        XCTAssertFalse(off.title.isEmpty)
    }
}
