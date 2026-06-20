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

    /// Terminate only if still running. Guards the race where the process exits just as
    /// the watchdog fires: `terminate()` on an already-exited `Process` raises.
    static func terminateIfRunning(_ process: Process) {
        if process.isRunning {
            process.terminate()
        }
    }
}
