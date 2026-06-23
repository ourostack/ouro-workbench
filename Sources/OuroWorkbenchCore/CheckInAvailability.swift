import Foundation

/// Whether the manual "Check In" affordance (the header button, its ⌘I shortcut,
/// the menubar item, the command palette, the autonomy popover) can run right now,
/// and — when it can't — why. The loudest control in the header used to be gated
/// only by `bossCheckInIsRunning`, so on a fresh machine with no boss it was fully
/// clickable and `runBossCheckIn()` returned silently: a dead affordance. This
/// pure, framework-free seam decides the states once so every surface agrees and
/// none of them silently no-ops.
///
/// - `.ready`            — a usable boss is set and nothing is in flight; the tap runs
///                         the check-in as it does today.
/// - `.noBoss`           — no boss chosen yet (fresh / factory-reset machine). The
///                         affordance routes the tap to the full set-up-a-boss
///                         onboarding pick.
/// - `.bossUnreachable`  — FIX 4: a boss IS configured but currently un-usable
///                         (daemon dead / bundle missing). This used to collapse into
///                         `.needsBoss` and dump the operator into the full onboarding
///                         pick — as if they'd never set up a boss. It now carries the
///                         agent's name and routes to a per-agent RECONNECT affordance
///                         + an honest "X isn't reachable" message, never re-onboarding.
/// - `.running`          — a check-in is already in flight; the affordance is disabled
///                         and re-entry is blocked.
public enum CheckInAvailability: Equatable, Sendable {
    case ready
    case noBoss
    case bossUnreachable(name: String)
    case running

    /// Resolve the availability from the boss selection and in-flight flag.
    ///
    /// - Parameters:
    ///   - bossAgentName: `state.boss.agentName`; empty/whitespace means "no boss
    ///     chosen yet" (→ `.noBoss`).
    ///   - bossIsUsable: whether the named boss resolves to an installed, ready
    ///     bundle (`ouroAgent(named:)?.isUsableAsBoss ?? false`). A named-but-
    ///     unusable boss can't actually answer, so it's `.bossUnreachable` (a
    ///     reconnect case), NOT no-boss.
    ///   - isRunning: `bossCheckInIsRunning`.
    public static func resolve(
        bossAgentName: String,
        bossIsUsable: Bool,
        isRunning: Bool
    ) -> CheckInAvailability {
        // An in-flight check-in owns the button regardless of boss state — the
        // re-entry guard already blocks a second run, and reporting a boss problem
        // mid-run would make the control flicker.
        if isRunning {
            return .running
        }
        let trimmed = bossAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // No boss chosen yet → the full onboarding pick.
            return .noBoss
        }
        if !bossIsUsable {
            // A boss IS configured but currently un-usable → reconnect THAT agent,
            // carrying its name for the honest message. NOT onboarding.
            return .bossUnreachable(name: trimmed)
        }
        return .ready
    }

    /// The tap may run the check-in immediately (only in `.ready`).
    public var canRunNow: Bool {
        self == .ready
    }

    /// The tap should route to the full set-up-a-boss ONBOARDING pick (only in
    /// `.noBoss`) — turning a would-be dead click into a guided next step. A
    /// configured-but-unreachable boss does NOT route here (it reconnects instead).
    public var routesToBossSetup: Bool {
        self == .noBoss
    }

    /// The tap should route to a per-agent RECONNECT affordance (only in
    /// `.bossUnreachable`) — bring the already-configured boss back online rather
    /// than re-onboarding from scratch.
    public var routesToReconnect: Bool {
        if case .bossUnreachable = self {
            return true
        }
        return false
    }

    /// The configured-but-unreachable boss's name, for driving the reconnect /
    /// the honest "X isn't reachable" message. Nil in every other state.
    public var unreachableBossName: String? {
        if case let .bossUnreachable(name) = self {
            return name
        }
        return nil
    }

    /// Who the manual check-in asks ("your boss" when no name resolves, otherwise
    /// the boss name) — never a blank, so no tooltip reads "Ask  what's going on".
    private static func bossSubject(bossAgentName: String) -> String {
        let trimmed = bossAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "your boss" : trimmed
    }

    /// One-line tooltip for a given availability, used as the `.help()` on every
    /// manual-check-in surface. Always distinguishes the one-shot ask from the
    /// automatic Boss Watch loop, and never interpolates a blank boss name.
    public static func helpText(for availability: CheckInAvailability, bossAgentName: String) -> String {
        let who = bossSubject(bossAgentName: bossAgentName)
        switch availability {
        case .ready:
            return "Ask \(who) what's going on across your sessions — what's running, "
                + "what's waiting on you, and what's next. Runs once now (⌘I) — "
                + "separate from the automatic Boss Watch loop."
        case .running:
            return "Asking \(who) what's going on across your sessions now. "
                + "This is the one-shot ask (⌘I), separate from the automatic Boss Watch loop."
        case .noBoss:
            return "No boss set up yet, so there's no one to check in with. "
                + "Set up a boss to ask what's going on and let it keep work moving."
        case let .bossUnreachable(name):
            // Honest + actionable: the boss exists, it just isn't reachable right
            // now. Point at reconnecting THAT agent, not setting up a new one.
            return "Your boss \(name) isn't reachable right now. "
                + "Reconnect it to check in — no need to set up a new boss."
        }
    }
}
