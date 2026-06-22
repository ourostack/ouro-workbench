import Foundation

/// The signal a watchdog should deliver to a child that ran past its deadline.
/// Named distinctly from the existing (unrelated) `ProcessTerminationPolicy`.
public enum WatchdogSignal: Equatable, Sendable {
    /// Not yet past the deadline — do nothing.
    case none
    /// SIGTERM — the polite first ask; a cooperative child flushes and exits.
    case terminate
    /// SIGKILL to the child pid ONLY. The safe default for a child spawned into a
    /// SHARED process group (a plain `Process()`): it reaps the direct child without
    /// touching the (shared) group.
    case killChild
    /// killpg(SIGKILL) — reaps the child AND its grandchildren. ONLY safe when the
    /// child is in its OWN process group; otherwise it would kill Workbench itself
    /// (a plain `Process()` SHARES Workbench's pgid). Returned only when the spawn
    /// opted into `SpawnInOwnGroup` (`POSIX_SPAWN_SETPGROUP`, pgid == child pid).
    case killGroup
}

/// Pure escalation policy for `ProcessWatchdog` AND `ProcessIOBox`. A wedged child that
/// ignores SIGTERM would otherwise hang forever; this decides — given how long it has
/// survived past the deadline — whether to send SIGTERM, escalate to SIGKILL, and (only
/// when provably safe) to SIGKILL the whole group.
///
/// The `childInOwnGroup` gate is the load-bearing safety check: `.killGroup` is returned
/// ONLY when it is `true`. A child spawned with a plain `Process()` shares Workbench's
/// process group, so a `killpg` would reap Workbench. The gate is wired to the SAME
/// boolean that selected the `SpawnInOwnGroup` path (`POSIX_SPAWN_SETPGROUP`) at the call
/// site, so killpg can NEVER fire for a shared-group child.
///
/// F8b live consumers: `ProcessIOBox.forceKill` (mcp-serve, `childInOwnGroup: true` — the
/// grandchild-leak fix) and `ProcessWatchdog.escalateTermination` (latent gated arm,
/// `childInOwnGroup` defaults `false` for every current finite-runner caller).
public enum WatchdogEscalation {
    /// - Parameters:
    ///   - elapsedSinceDeadline: seconds since the watchdog's timeout fired (i.e. since
    ///     the first SIGTERM would have been sent). Negative means the deadline hasn't
    ///     passed yet.
    ///   - graceSeconds: how long to let SIGTERM work before escalating to SIGKILL.
    ///   - childInOwnGroup: proven `true` ONLY when the spawn placed the child in its own
    ///     process group (`POSIX_SPAWN_SETPGROUP`). Gates `.killGroup`.
    public static func nextSignal(
        elapsedSinceDeadline: Double,
        graceSeconds: Double,
        childInOwnGroup: Bool
    ) -> WatchdogSignal {
        if elapsedSinceDeadline < 0 {
            return .none
        }
        if elapsedSinceDeadline < graceSeconds {
            return .terminate
        }
        return childInOwnGroup ? .killGroup : .killChild
    }
}
