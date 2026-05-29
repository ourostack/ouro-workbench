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
