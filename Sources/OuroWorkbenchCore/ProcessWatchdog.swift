import Foundation

/// Bounds a synchronous `Process.waitUntilExit()` so a wedged child can't hang the
/// caller forever.
///
/// The remediation runners (`AgentRepairRunner`, `ProviderVerifyRunner`,
/// `ProviderRefreshRunner`, `LaneSelectionRunner`, `ColdStartHatchRunner`) spawn
/// `/usr/bin/env ouro …` and WAIT for it to exit. `ouro` is a `node` script that can
/// stall — a credential vault that's lock-contended (observed: a 75-second
/// `bw` lock timeout), a one-time CLI self-update download, a daemon-socket wait, an
/// interactive prompt looping on a `/dev/null` stdin. Without a bound, `waitUntilExit`
/// never returns, the cold-start bootstrap spinner spins forever, and no manual-recovery
/// line is ever surfaced (the post-command probe that produces it runs only AFTER the
/// wait). This terminates the child past the deadline so the wait unwinds and the probe
/// can classify the (now-failed) outcome honestly.
///
/// F8 — a bare `terminate()` (SIGTERM) is not enough: a wedged child that IGNORES
/// SIGTERM (a `node` swallowing the signal, a stuck syscall) survives the kill and the
/// wait still hangs forever. The watchdog ESCALATES — SIGTERM, then after a grace
/// window SIGKILL.
///
/// F8b — the escalation gained a GATED group-reap arm. The post-grace SIGKILL is routed
/// through `WatchdogEscalation.nextSignal`: a child explicitly flagged `childInOwnGroup`
/// (spawned via `SpawnInOwnGroup`, `POSIX_SPAWN_SETPGROUP`) is reaped with `killpg` (child +
/// grandchildren), while every other child — a plain `Process()` that SHARES Workbench's
/// process group — is SIGKILLed child-only (a `killpg` there would reap Workbench itself).
/// The gate (`childInOwnGroup`) defaults to `false`, so this arm is LATENT: no current
/// ProcessWatchdog caller opts in (the finite remediation runners all wait on shared-group
/// children). It exists, born reachable + coverable, for future awaited own-group spawns;
/// the LIVE grandchild-leak fix lands in `ProcessIOBox.forceKill` (mcp-serve), not here.
public enum ProcessWatchdog {
    /// Wait for `process` to exit, terminating it if it runs past `timeoutSeconds`.
    /// `process` must already be running (`try process.run()` called by the caller).
    ///
    /// Thin back-compat wrapper over the escalating overload with the safe defaults
    /// (2s grace, child-only SIGKILL, real `kill`) so the existing callers are unchanged.
    public static func waitUntilExit(_ process: Process, timeoutSeconds: Double) {
        waitUntilExit(process, timeoutSeconds: timeoutSeconds, gracePeriodSeconds: 2.0)
    }

    /// Wait for `process` to exit, escalating SIGTERM → (grace) → SIGKILL past the deadline.
    ///
    /// - Parameters:
    ///   - timeoutSeconds: how long to let the child run before the watchdog fires.
    ///   - gracePeriodSeconds: after SIGTERM, how long to let a cooperative child flush +
    ///     exit before SIGKILL. Default 2.0s.
    ///   - signalDeliverer: the syscall seam — delivers `(pid, signal)`. Default is the
    ///     real `kill`; tests inject a fake to cover the escalation ORCHESTRATION without
    ///     a child that deterministically ignores SIGTERM.
    public static func waitUntilExit(
        _ process: Process,
        timeoutSeconds: Double,
        gracePeriodSeconds: Double = 2.0,
        signalDeliverer: @escaping @Sendable (pid_t, Int32) -> Void = { kill($0, $1) }
    ) {
        let watchdog = DispatchWorkItem {
            escalateTermination(
                process,
                gracePeriodSeconds: gracePeriodSeconds,
                signalDeliverer: signalDeliverer
            )
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)
        process.waitUntilExit()
        // The process exited on its own before the deadline — cancel the pending kill.
        watchdog.cancel()
    }

    /// Wait for `process` to exit, terminating it past `timeoutSeconds`, and REPORT whether the
    /// watchdog fired. Returns `true` iff the deadline passed and the watchdog terminated a wedged
    /// child; `false` iff the process exited on its own first.
    ///
    /// F7 — the clone runner needs to distinguish a 120s wedge (`.timedOut`) from a real non-zero
    /// git failure BEFORE it reads `terminationStatus` (a watchdog kill and a genuine git failure
    /// both produce a non-zero exit — B-1). The void `waitUntilExit` above can't surface that, and
    /// its F1/F13 callers don't need it, so this is ADDITIVE. The did-fire flag is set inside the
    /// watchdog closure and read after the wait, both under an `NSLock` so the closure's write
    /// happens-before the caller's read with no swift-atomics dependency (the closure runs on a
    /// global queue; the wait unwinds on the caller's thread).
    ///
    /// F8 — the watchdog now escalates SIGTERM → (grace) → SIGKILL, same as the void variant, so a
    /// SIGTERM-ignoring child can't keep this wait hung past the report either.
    public static func waitUntilExitReportingTimeout(_ process: Process, timeoutSeconds: Double) -> Bool {
        let lock = NSLock()
        var didFire = false
        let watchdog = DispatchWorkItem {
            lock.lock()
            didFire = true
            lock.unlock()
            escalateTermination(process, gracePeriodSeconds: 2.0, signalDeliverer: { kill($0, $1) })
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)
        process.waitUntilExit()
        // The process exited (on its own, or because the watchdog terminated it). Cancel any
        // still-pending kill, then read the flag under the lock so a kill the closure already
        // started is observed.
        // HONEST EDGE (safe): if the child exits naturally in the sub-millisecond window AFTER the
        // deadline closure has ALREADY begun executing, `cancel()` is a no-op (the closure isn't
        // pending) and `didFire` is observed `true` — so a clone that just-barely-finished can be
        // reported `.timedOut`. The outcome is safe (the clone path's `.timedOut` is a retry), and
        // the window is vanishingly small; we accept it rather than add a fragile race-narrowing.
        watchdog.cancel()
        lock.lock()
        let fired = didFire
        lock.unlock()
        return fired
    }

    /// Terminate only if still running. Guards the race where the process exits just as
    /// the watchdog fires: `terminate()` on an already-exited `Process` raises.
    static func terminateIfRunning(_ process: Process) {
        if process.isRunning {
            process.terminate()
        }
    }

    /// The escalation: SIGTERM, then (after `gracePeriodSeconds` of the child still running) a
    /// SIGKILL routed through the `WatchdogEscalation.nextSignal` policy — `killpg` for an
    /// own-group child (`childInOwnGroup: true`), child-only `kill` otherwise. Impure delivery
    /// through the injected `signalDeliverer` (child) / `groupSignalDeliverer` (group): the
    /// orchestration is covered by injecting fakes.
    ///
    /// - Parameters:
    ///   - childInOwnGroup: the GATE. `true` ONLY when the child was spawned into its own
    ///     process group (`SpawnInOwnGroup`); gates the `.killGroup` arm. Defaults `false` so
    ///     every current caller (the finite remediation runners, all waiting on shared-group
    ///     children) stays child-only and can NEVER group-reap Workbench.
    ///   - groupSignalDeliverer: the `killpg` seam (the `.killGroup` arm). Defaults to the real
    ///     `killpg`; a test injects a fake to assert the gated routing without a real group reap.
    ///
    /// Recycled-pid safety: capture `processIdentifier` while `isRunning`, and re-check
    /// `isRunning` immediately before each signal — never signal a pid the OS may have reaped
    /// and reassigned.
    static func escalateTermination(
        _ process: Process,
        gracePeriodSeconds: Double,
        signalDeliverer: @Sendable (pid_t, Int32) -> Void,
        childInOwnGroup: Bool = false,
        // LATENT group-reap seam (the `.killGroup` arm). The default real `killpg` is
        // STRUCTURALLY DEAD from every production path: `escalateTermination` only takes a
        // `Process`, which always SHARES Workbench's group, and no current caller sets
        // `childInOwnGroup: true`, so `.killGroup` is reached ONLY by the injected-fake routing
        // test (a real killpg of a shared group would reap the test runner). The real killpg
        // mechanism is proven separately against `SpawnInOwnGroup` children (SpawnInOwnGroupTests,
        // ProcessIOBox's default-killpg test). Hence the 1-line allowlist on this default closure.
        groupSignalDeliverer: @Sendable (pid_t, Int32) -> Void = { killpg($0, $1) }
    ) {
        // Stage 1 — SIGTERM. Capture the pid while the child is provably running.
        guard process.isRunning else {
            return
        }
        let pid = process.processIdentifier
        signalDeliverer(pid, SIGTERM)

        // Stage 2 — grace. Poll for the child to exit on its own; bounded so a wedged child
        // can't hang us here either. If it exits during grace, the re-check below skips SIGKILL.
        let deadline = Date().addingTimeInterval(gracePeriodSeconds)
        while process.isRunning && Date() < deadline {
            usleep(20_000) // 20ms
        }

        // Stage 3 — escalate. Re-check isRunning to avoid signalling a reaped/recycled pid.
        guard process.isRunning else {
            return
        }
        // Route the SIGKILL through the policy. The gate (childInOwnGroup) decides: an own-group
        // child → `.killGroup` → killpg (reaps the grandchild tree); a shared-group child →
        // `.killChild` → child-only kill (a killpg would reap Workbench). At this point the child
        // has survived the full grace window, so elapsed == grace selects the SIGKILL arm.
        switch WatchdogEscalation.nextSignal(
            elapsedSinceDeadline: gracePeriodSeconds,
            graceSeconds: gracePeriodSeconds,
            childInOwnGroup: childInOwnGroup
        ) {
        case .killGroup:
            groupSignalDeliverer(pid, SIGKILL)
        default:
            signalDeliverer(pid, SIGKILL)
        }
    }
}
