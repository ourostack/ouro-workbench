import Foundation

/// The boss's verdict on whether a (re)started session came up and is healthy.
/// Deliberately general — no agency / harness-specific knowledge; derived purely
/// from a run status, a transcript tail, and recency timing.
public enum SessionHealth: String, Codable, Equatable, Sendable, CaseIterable {
    /// Up and responsive: producing fresh output, sitting at a prompt waiting on
    /// the human, or exited cleanly (code 0).
    case healthy
    /// Still coming up: no output yet and within the startup grace window, or no
    /// run status recorded yet.
    case starting
    /// Claims to be running but has gone quiet — output stopped past the stalled
    /// threshold, or nothing emitted well past the startup grace. Not waiting on
    /// a prompt (that's `healthy`).
    case stalled
    /// Did not stay up: exited non-zero (or with no code), the run needs
    /// recovery / manual action, or the transcript ended on a terminal error.
    case failed
}

/// Pure classifier the boss uses to confirm a resumed session is healthy,
/// composing the existing surfaces (`workbench_sessions` run status + recency,
/// `workbench_transcript_tail` text) into a single verdict — so the boss gets a
/// deterministic, covered answer instead of re-interpreting raw output itself.
///
/// Reuses `AttentionSignalDetector.classify(tail:)` for the prompt-waiting /
/// terminal-error reading of the tail (same detector the sidebar uses), so the
/// health verdict agrees with the rest of the workbench. No I/O, no timers —
/// every input (elapsed times, exit code) is passed in, making it exhaustively
/// unit-testable. The MCP layer can expose this verbatim if a tool is wanted;
/// it adds value as Core because the classification — not the byte-fetching — is
/// the part worth pinning.
public enum SessionHealthProbe {
    /// Output quiet for at least this long (while running and not at a prompt)
    /// reads as stalled. Matches the sidebar's `SessionChip.stalledThreshold`.
    public static let defaultStalledThreshold: TimeInterval = 90
    /// A running session with no output yet is still "starting" until this much
    /// time has elapsed since it started; past it, no output reads as stalled.
    public static let defaultStartupGrace: TimeInterval = 20

    /// Classify a session's health from its latest run status, transcript tail,
    /// and recency timing.
    ///
    /// - Parameters:
    ///   - runStatus: latest run's `ProcessStatus` (nil when there's no run yet).
    ///   - tail: the transcript tail text (nil / empty when nothing emitted yet).
    ///   - elapsedSinceStart: seconds since the run started (nil when unknown).
    ///   - elapsedSinceOutput: seconds since the last output (nil when none yet).
    ///   - exitCode: the run's exit code when `runStatus == .exited`.
    ///   - stalledThreshold / startupGrace: tunable windows (defaults above).
    public static func classify(
        runStatus: ProcessStatus?,
        tail: String?,
        elapsedSinceStart: TimeInterval?,
        elapsedSinceOutput: TimeInterval?,
        exitCode: Int? = nil,
        stalledThreshold: TimeInterval = defaultStalledThreshold,
        startupGrace: TimeInterval = defaultStartupGrace
    ) -> SessionHealth {
        let signal = tailSignal(tail)

        // 1. Hard failures from the run status take precedence — the session did
        //    not stay up.
        switch runStatus {
        case .exited:
            // Clean exit (code 0) = success; anything else (incl. no code) = failed.
            return exitCode == 0 ? .healthy : .failed
        case .needsRecovery, .manualActionNeeded:
            return .failed
        case .running, .waitingForInput, .configured, .none:
            break
        }

        // 2. A terminal error as the last thing printed is a failure even if the
        //    run status hasn't caught up yet.
        if signal == .blocked {
            return .failed
        }

        // 3. Waiting at a prompt means it came up and is responsive — healthy,
        //    not stalled, regardless of how long the prompt has sat. Covers both
        //    the explicit `.waitingForInput` run status and a prompt detected in
        //    the tail while still `.running`.
        if runStatus == .waitingForInput || signal == .waitingOnHuman {
            return .healthy
        }

        // 4. No output yet → still starting within the grace window, else stalled.
        if !hasOutput(tail) {
            if let elapsed = elapsedSinceStart, elapsed > startupGrace {
                return .stalled
            }
            return .starting
        }

        // 5. Has output → stalled once it's gone quiet past the threshold,
        //    otherwise healthy.
        if let quiet = elapsedSinceOutput, quiet > stalledThreshold {
            return .stalled
        }
        return .healthy
    }

    /// Convenience overload reading the run facts off a `SessionSnapshot` (the
    /// `workbench_sessions` row) and computing the elapsed windows from `now`.
    public static func classify(
        snapshot: SessionSnapshot,
        tail: String?,
        now: Date = Date(),
        stalledThreshold: TimeInterval = defaultStalledThreshold,
        startupGrace: TimeInterval = defaultStartupGrace
    ) -> SessionHealth {
        classify(
            runStatus: ProcessStatus(rawValue: snapshot.status),
            tail: tail,
            elapsedSinceStart: snapshot.startedAt.map { now.timeIntervalSince($0) },
            elapsedSinceOutput: snapshot.lastOutputAt.map { now.timeIntervalSince($0) },
            exitCode: snapshot.exitCode,
            stalledThreshold: stalledThreshold,
            startupGrace: startupGrace
        )
    }

    /// The tail's attention signal, or `.unknown` when there's no usable tail.
    private static func tailSignal(_ tail: String?) -> AttentionSignal {
        guard let tail, hasOutput(tail) else { return .unknown }
        return AttentionSignalDetector.classify(tail: tail)
    }

    /// Whether the tail carries any visible content.
    private static func hasOutput(_ tail: String?) -> Bool {
        guard let tail else { return false }
        return !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
