import Foundation

/// Debounce policy for re-checking the live agent-readiness overlay.
///
/// PRs #261/#262/#264 made readiness honest by overlaying a live `ouro check`
/// verdict, refreshed on launch + the navigation/action triggers that call
/// `refreshOuroAgents()`. But an app left FOCUSED + IDLE on one view never
/// re-checks, so a provider token that expires mid-session leaves a STALE
/// "ready" pill until the user manually navigates. Two new triggers close that
/// gap — an app-became-active re-check and a periodic backstop — and BOTH route
/// through this policy so they neither hammer the daemon nor double-fire.
///
/// Pure by construction: `now` is injected (no wall-clock read here), so the
/// rule is fully deterministic and testable.
public enum AgentReadinessRefreshPolicy {
    /// True when a re-check should fire: never checked yet (`lastCheckedAt == nil`),
    /// or at least `staleAfter` seconds have elapsed since the last check.
    ///
    /// A backwards clock skew (`now` < `lastCheckedAt`, i.e. negative elapsed) is
    /// deliberately NOT treated as stale — otherwise skew would spam checks.
    public static func shouldRefresh(
        lastCheckedAt: Date?,
        now: Date,
        staleAfter: TimeInterval
    ) -> Bool {
        guard let lastCheckedAt else { return true }
        return now.timeIntervalSince(lastCheckedAt) >= staleAfter
    }
}
