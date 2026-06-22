import Foundation

/// The signal a watchdog should deliver to a child that ran past its deadline.
/// Named distinctly from the existing (unrelated) `ProcessTerminationPolicy`.
public enum WatchdogSignal: Equatable, Sendable {
    /// Not yet past the deadline — do nothing.
    case none
    /// SIGTERM — the polite first ask; a cooperative child flushes and exits.
    case terminate
    /// SIGKILL to the child pid ONLY. The safe default for every current spawn:
    /// it reaps the direct child without touching the (shared) process group.
    case killChild
    /// killpg(SIGKILL) — reaps the child AND its grandchildren. ONLY safe when the
    /// child is in its OWN process group; otherwise it would kill Workbench itself
    /// (today's spawns SHARE Workbench's pgid). No current call site opts in.
    case killGroup
}

/// Pure escalation policy for `ProcessWatchdog`. A wedged child that ignores SIGTERM
/// would otherwise hang forever; this decides — given how long it has survived past the
/// deadline — whether to send SIGTERM, escalate to SIGKILL, and (only when provably
/// safe) to SIGKILL the whole group.
///
/// The `childInOwnGroup` gate is the load-bearing safety check: `.killGroup` is returned
/// ONLY when it is `true`. Spawned `ouro` children currently share Workbench's process
/// group, so a `killpg` would reap Workbench. The gate is wired to the same boolean that
/// would set `POSIX_SPAWN_SETPGROUP`, so killpg can NEVER fire for a shared-group child.
/// In F8 no spawn opts in, so `.killGroup` is structurally unreachable from every call
/// site — the grandchild-reaping `posix_spawn` opt-in is a sequenced follow-up.
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
