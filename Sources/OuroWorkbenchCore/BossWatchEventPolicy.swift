import Foundation

/// Decides whether a "session just needs attention" event should kick an
/// immediate boss check-in (the event-driven, responsive path), or be left to
/// the periodic poll. Pure so the rate-limit + guards are unit-tested rather
/// than buried in the view model. The check-in itself re-guards, so this is a
/// throttle, not the sole gate.
public enum BossWatchEventPolicy {
    public static func shouldTriggerCheckIn(
        watchEnabled: Bool,
        busy: Bool,
        lastTriggerAt: Date?,
        now: Date,
        cooldown: TimeInterval
    ) -> Bool {
        guard watchEnabled, !busy else {
            return false
        }
        if let lastTriggerAt, now.timeIntervalSince(lastTriggerAt) < cooldown {
            return false
        }
        return true
    }
}

/// Exponential backoff for the automatic Boss Watch loop after the boss check-in
/// keeps failing (boss down, misconfigured, returning empty). Without this, a
/// dead boss is re-invoked every poll interval forever — spawning a failing
/// subprocess a minute, indefinitely. Pure + tested. A *manual* check-in is
/// never gated by this; only the automatic loop/event triggers are.
public enum BossWatchBackoff {
    /// After `consecutiveFailures` failed automatic check-ins, how long to wait
    /// before the next automatic attempt. 0 failures → 0 (no backoff). Doubles
    /// from `base` each failure, capped at `cap`.
    public static func delay(
        consecutiveFailures: Int,
        base: TimeInterval = 60,
        cap: TimeInterval = 900
    ) -> TimeInterval {
        guard consecutiveFailures > 0 else {
            return 0
        }
        let exponent = min(consecutiveFailures - 1, 16)
        let scaled = base * pow(2, Double(exponent))
        return min(scaled, cap)
    }

    /// Whether the automatic loop may attempt a check-in now, given the next
    /// allowed retry time computed at the last failure.
    public static func mayAttempt(now: Date, nextRetryAt: Date?) -> Bool {
        guard let nextRetryAt else {
            return true
        }
        return now >= nextRetryAt
    }
}
