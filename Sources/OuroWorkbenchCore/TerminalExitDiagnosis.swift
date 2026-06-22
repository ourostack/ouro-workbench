import Foundation

/// Maps a `screen`-wrapped session's exit to ONE honest operator sentence (#F12a
/// gap 2) — the same phrasebook idiom `RecoveryReasonPhrasebook` uses for
/// `RecoveryAction`.
///
/// Every custom Workbench session launches through `screen` (the outer terminal
/// multiplexer — `PersistentTerminalSession.executable`). When `screen` itself is
/// missing or not runnable, the wrapped command can't exec and the session exits
/// **127** ("command not found"). The old path rendered a dead-end "exited with
/// code 127" + re-spawned the same missing-screen, looping forever. This seam turns
/// the `(exitCode, screen-health)` pair into a sentence that tells the operator what
/// actually went wrong — or `nil` when there's nothing screen-specific to say (so
/// the caller keeps its generic exit message).
///
/// The 127 gate is deliberate: only a 127 is the multiplexer's "couldn't exec"
/// signature. Any other code — or a signal (nil) — is the INNER agent's own exit and
/// must never be misattributed to a missing `screen`.
public enum TerminalExitDiagnosis: Sendable {
    /// A one-line diagnosis for a `screen`-wrapped session that exited `exitCode`,
    /// given the live health of the `screen` executable. Returns `nil` for any
    /// non-127 exit (nothing screen-specific to add) so the caller falls back to its
    /// generic "exited with code N" line.
    public static func screenWrappedExit(
        exitCode: Int32?,
        screenHealth: ExecutableHealthStatus
    ) -> String? {
        guard exitCode == 127 else {
            return nil
        }
        switch screenHealth {
        case .missing, .notExecutable:
            return "The terminal multiplexer (screen) is missing or not runnable — reinstall it, then recover this session."
        case .available:
            return "Exited 127 (command not found) — the command may not be on PATH for this session."
        }
    }
}
