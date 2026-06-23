/// The pure, framework-free presentation seam for the boss's MCP-registration pill — the
/// missing verdict-aware layer this fix adds. The bug it replaces: every pill surface
/// computed its colour/label from the registration STATUS ALONE, so a config-only
/// `.registered` snapshot read GREEN "registered / available at runtime" even though NO
/// live injection probe had confirmed the `workbench_*` tools actually inject into the
/// boss. A registered-but-never-verified agent (e.g. an old `ouro` that silently strips
/// `--workbench-mcp`) therefore looked runtime-ready when it might not be.
///
/// HONESTY INVARIANT: `.verified` (the only green) is reachable ONLY when the status is
/// `.registered` AND a live injection probe CONFIRMED the tools PRESENT
/// (`.confirmed(.present)`). A registered snapshot with a `nil` (never probed) /
/// `.unconfirmed` / confirmed-`.absent` verdict is `.unverified` — NEUTRAL, never green —
/// "registered in config, runtime injection not yet confirmed".
///
/// INVERSE-BUG WATCH (#262): unverified ≠ broken. `.unverified` is NEUTRAL (pending), never
/// a hard red/error — the common pre-probe window must NOT over-alarm into looking failed.
/// And a genuinely confirmed-present injection MUST still read green.
public enum BossMCPPillPresentation {

    /// The semantic state of the pill, decoupled from any UI framework.
    public enum Tone: Equatable, Sendable {
        /// `.registered` + CONFIRMED-PRESENT injection — the ONLY green.
        case verified
        /// `.registered` but injection not confirmed present (nil / unconfirmed /
        /// confirmed-absent-while-still-registered) — NEUTRAL, not green, not red.
        case unverified
        /// `.toolsNotInjected` — a confirmed-absent verdict overlaid onto the snapshot.
        case notInjected
        /// `.needsUpdate` — a stale bundle entry to clean up.
        case needsAttention
        /// `.notRegistered` — Workbench tools not wired up yet.
        case notRegistered
        /// `.agentMissing` / `.executableMissing` / `.invalidConfig` — structural failure.
        case error
    }

    /// Framework-free colour classes; the App maps these to SwiftUI `Color`s.
    public enum SemanticColor: Equatable, Sendable {
        case green
        case neutral
        case orange
        case red
    }

    /// The honest tone for a registration status folded with its live injection verdict.
    /// `.verified` is reachable ONLY from `.registered` + `.confirmed(.present)`; every
    /// other registered combination is `.unverified` (neutral). Non-registered statuses
    /// ignore the injection verdict — the registration problem is the real story.
    public static func tone(
        status: BossWorkbenchMCPRegistrationStatus,
        injection: WorkbenchToolsInjectionProbeOutcome?
    ) -> Tone {
        switch status {
        case .registered:
            // Green ONLY when a live probe confirmed the tools are present. Everything
            // else (never probed / timed-out / confirmed-absent-but-not-yet-overlaid) is
            // honestly "registered, unverified" — neutral, never green, never red.
            switch injection {
            case .confirmed(.present):
                return .verified
            case .confirmed(.absent), .unconfirmed, .none:
                return .unverified
            }
        case .toolsNotInjected:
            return .notInjected
        case .needsUpdate:
            return .needsAttention
        case .notRegistered:
            return .notRegistered
        case .agentMissing, .executableMissing, .invalidConfig:
            return .error
        }
    }

    /// The semantic colour for a tone. Only `.verified` is green; `.unverified` is the
    /// calm neutral of a pending, not-yet-confirmed state.
    public static func color(for tone: Tone) -> SemanticColor {
        switch tone {
        case .verified:
            return .green
        case .unverified:
            return .neutral
        case .notInjected, .needsAttention, .notRegistered:
            return .orange
        case .error:
            return .red
        }
    }

    /// The pill label for a tone. `.verified` reads the plain "registered"; `.unverified`
    /// is visibly qualified so a human can tell "config says registered" from "runtime
    /// confirmed".
    public static func label(for tone: Tone) -> String {
        switch tone {
        case .verified:
            return "registered"
        case .unverified:
            return "registered (unverified)"
        case .notInjected:
            return "tools not injected"
        case .needsAttention:
            return "needs update"
        case .notRegistered:
            return "not registered"
        case .error:
            return "registration error"
        }
    }
}
