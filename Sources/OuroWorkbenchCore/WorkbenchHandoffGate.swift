import Foundation

/// The pure decision the App's handoff `statusPing` closure delegates to (#F9). Today the
/// closure ends Layer A on the first successful boss-native `status` round-trip alone — which
/// an old `ouro` answers fine even after silently stripping every `workbench_*` tool. This
/// gate folds the `status` result together with the `tools/list` injection probe so handoff
/// requires CONFIRMED tool injection, and — critically — distinguishes a confirmed strip (the
/// hard blocker) from a probe that couldn't answer (stay awaiting, unconfirmed).
public enum WorkbenchHandoffGate {

    /// The three terminal shapes of the handoff edge.
    public enum Outcome: String, Equatable, Sendable {
        /// Not ready yet — the boot stays at `.awaitingHandoff`. Covers a failed `status`
        /// ping AND a status-ok-but-injection-unconfirmed (slow cold start) — neither is a
        /// known failure, so neither lights a blocker.
        case awaitingHandoff
        /// `status` ok AND the probe CONFIRMED ≥1 `workbench_*` tool — the boss can drive
        /// Workbench. The only path that hands off.
        case handedOff
        /// `status` ok BUT the probe CONFIRMED zero `workbench_*` tools — an old `ouro`
        /// stripped them. Stay awaiting, and flip the registration to `.toolsNotInjected`.
        case toolsStripped
    }

    public struct Decision: Equatable, Sendable {
        public let outcome: Outcome

        public init(outcome: Outcome) {
            self.outcome = outcome
        }

        /// What the App closure returns to `AgentReadinessBootstrap`: true ONLY when handed
        /// off. `.toolsStripped` and `.awaitingHandoff` both map a `false` ping to
        /// `.awaitingHandoff` — never `.handedOff` with stripped tools.
        public var isHandedOff: Bool { outcome == .handedOff }

        /// True iff the probe CONFIRMED zero tools — the App caches this to flip the
        /// published registration to `.toolsNotInjected` (the loud blocker). An unconfirmed
        /// probe is NOT this — a slow cold start must not false-report "too old".
        public var toolsConfirmedStripped: Bool { outcome == .toolsStripped }
    }

    public static func decide(
        statusPingSucceeded: Bool,
        injectionProbe: WorkbenchToolsInjectionProbeOutcome
    ) -> Decision {
        guard statusPingSucceeded else {
            return Decision(outcome: .awaitingHandoff)
        }
        switch injectionProbe {
        case .confirmed(.present):
            return Decision(outcome: .handedOff)
        case .confirmed(.absent):
            return Decision(outcome: .toolsStripped)
        case .unconfirmed:
            // The probe couldn't answer (timeout / spawn error) — stay awaiting, UNCONFIRMED.
            return Decision(outcome: .awaitingHandoff)
        }
    }
}
