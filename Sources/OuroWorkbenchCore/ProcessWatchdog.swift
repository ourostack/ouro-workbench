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
public enum ProcessWatchdog {
    /// Wait for `process` to exit, terminating it if it runs past `timeoutSeconds`.
    /// `process` must already be running (`try process.run()` called by the caller).
    public static func waitUntilExit(_ process: Process, timeoutSeconds: Double) {
        let watchdog = DispatchWorkItem {
            terminateIfRunning(process)
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
    public static func waitUntilExitReportingTimeout(_ process: Process, timeoutSeconds: Double) -> Bool {
        let lock = NSLock()
        var didFire = false
        let watchdog = DispatchWorkItem {
            lock.lock()
            didFire = true
            lock.unlock()
            terminateIfRunning(process)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)
        process.waitUntilExit()
        // The process exited (on its own, or because the watchdog terminated it). Cancel any
        // still-pending kill, then read the flag under the lock so a kill the closure already
        // started is observed.
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
}
