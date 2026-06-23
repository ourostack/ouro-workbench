import Foundation

/// FIX 2 (MED) — honest copy for a FAILED boss Check In. The product-voice failure
/// line and the persistent "agent isn't answering" banner used to promise an
/// automatic retry ("Workbench will try again shortly" / "keeps trying, a little
/// less often each time"). But the ONLY retry driver is the automatic
/// `runBossWatchLoop`, gated on `bossWatchIsEnabled` — and Boss Watch is OFF by
/// default. So with the watch off a manual Check In that failed promised a retry
/// that never came: the operator waited forever.
///
/// This pure seam selects the copy as a function of (failureCount, bossWatchIsEnabled):
/// - Watch OFF → no auto-retry promise; tell the operator to press Check In again.
/// - Watch ON  → keep the truthful "will try again" copy (the loop IS retrying, with
///   exponential backoff per `BossWatchBackoff`).
///
/// Framework-free so the branch is unit-tested rather than buried in the view /
/// view model. The catch path renders `failureLine`; the persistent banner renders
/// `persistentBanner`.
public enum BossCheckInFailureCopy {

    /// The transient product-voice line set as `bossCheckInAnswer` right after a
    /// failed ask. Never leaks the raw transport/CLI error (that stays in the audit
    /// log) — fixed, seam-free copy.
    public static func failureLine(failureCount: Int, bossWatchIsEnabled: Bool) -> String {
        if bossWatchIsEnabled {
            // Boss Watch is running, so the automatic loop genuinely retries — the
            // "will try again" promise is TRUE. Unchanged from the pre-fix copy.
            return "Your agent didn't answer just now. Workbench will try again shortly."
        }
        // Boss Watch is off: nothing retries on its own. Tell the operator the real
        // next step instead of promising a retry that won't happen.
        return "Check-In didn't go through. Press Check In to try again."
    }

    /// The prominent banner surfaced after `>= 2` consecutive failures (boss down /
    /// misconfigured). Title is stable across watch state; the detail + guidance
    /// branch on whether an automatic retry is actually happening.
    public struct PersistentBanner: Equatable {
        public var title: String
        public var detail: String
        public var guidance: String

        public init(title: String, detail: String, guidance: String) {
            self.title = title
            self.detail = detail
            self.guidance = guidance
        }
    }

    public static func persistentBanner(failureCount: Int, bossWatchIsEnabled: Bool) -> PersistentBanner {
        let title = "Your agent isn't answering yet"
        if bossWatchIsEnabled {
            // The automatic loop is genuinely still retrying (with backoff) — keep
            // the truthful copy. Unchanged from the pre-fix banner.
            return PersistentBanner(
                title: title,
                detail: "Your agent didn't answer the last \(failureCount) times. Workbench is still trying.",
                guidance: "Workbench keeps trying, a little less often each time — press Check In to try now."
            )
        }
        // Boss Watch is off: there's no automatic retry. Report the failures honestly
        // and tell the operator the manual next step — don't claim Workbench "keeps
        // trying."
        return PersistentBanner(
            title: title,
            detail: "Your agent didn't answer the last \(failureCount) times.",
            guidance: "Workbench won't keep trying on its own — press Check In to try again."
        )
    }
}
