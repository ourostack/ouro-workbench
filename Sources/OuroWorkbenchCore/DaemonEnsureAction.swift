import Foundation

/// The agent-action surfacing wrapper for the `ensureDaemon` onboarding remediation.
///
/// `ensureDaemon` WRAPS Slice 0's `DaemonManager.ensureRunning()` (detect-reuse-else-start) as
/// an agent-issuable action. The recovery truth is the EXISTING `DaemonRecoveryTruth`
/// classification (derived from `DaemonManager`'s post-start verify probe, never an exit code) —
/// this wrapper adapts a `DaemonStartOutcome` for surfacing in `bossAppliedActions`.
///
/// The one adaptation: `DaemonStartOutcome.humanFacingStartupLine` is `nil` on `resumed` (a
/// check-in should proceed silently when the daemon was already up). An agent-issued action,
/// by contrast, must always report SOMETHING back to the agent's narration — so this wrapper
/// gives a non-nil seam-free line on every outcome, including resumed.
public struct DaemonEnsureActionOutcome: Equatable, Sendable {
    /// The underlying detect-reuse-else-start outcome (recovery truth + liveness).
    public let start: DaemonStartOutcome

    public init(start: DaemonStartOutcome) {
        self.start = start
    }

    /// True only when the daemon could not be brought up — surfaces an honest manual line.
    public var needsManualRecovery: Bool {
        start.needsManualRecovery
    }

    /// True only when the daemon is genuinely up after the cycle (the verify-probe truth),
    /// never off a spawn exit code.
    public var succeeded: Bool {
        start.liveness == .up
    }

    /// Human-facing, seam-free copy. COHESIVE-PRODUCT CONTRACT: never exposes a CLI seam
    /// (`ouro up`, `daemon`). Always non-empty — an agent action reports back on every outcome
    /// (the silent-resumed behavior is specific to a check-in, not an agent-issued action).
    public var humanFacingLine: String {
        if let line = start.humanFacingStartupLine {
            return line
        }
        // resumed: the daemon was already up. Report readiness rather than stay silent.
        return "Your agent's connection is already online."
    }

    /// Audit/debug detail line (raw `ouro` verbs allowed here only) — passthrough from the
    /// underlying recovery truth so callers have one source of truth.
    public var auditDetail: String {
        start.auditDetail
    }
}
