import Foundation

/// Whether the manual "Check In" affordance (the header button, its ⌘I shortcut,
/// the menubar item, the command palette, the autonomy popover) can run right now,
/// and — when it can't — why. The loudest control in the header used to be gated
/// only by `bossCheckInIsRunning`, so on a fresh machine with no boss it was fully
/// clickable and `runBossCheckIn()` returned silently: a dead affordance. This
/// pure, framework-free seam decides the three states once so every surface agrees
/// and none of them silently no-ops.
///
/// - `.ready`     — a usable boss is set and nothing is in flight; the tap runs the
///                  check-in as it does today.
/// - `.needsBoss` — no usable boss (no boss chosen yet, or a named boss whose
///                  bundle isn't installed/ready). The affordance routes the tap to
///                  the set-up-a-boss flow instead of doing nothing.
/// - `.running`   — a check-in is already in flight; the affordance is disabled and
///                  re-entry is blocked.
public enum CheckInAvailability: Equatable, Sendable {
    case ready
    case needsBoss
    case running

    /// Resolve the availability from the boss selection and in-flight flag.
    ///
    /// - Parameters:
    ///   - bossAgentName: `state.boss.agentName`; empty/whitespace means "no boss
    ///     chosen yet".
    ///   - bossIsUsable: whether the named boss resolves to an installed, ready
    ///     bundle (`ouroAgent(named:)?.isUsableAsBoss ?? false`). A named-but-
    ///     unusable boss can't actually answer, so it's treated as needs-boss.
    ///   - isRunning: `bossCheckInIsRunning`.
    public static func resolve(
        bossAgentName: String,
        bossIsUsable: Bool,
        isRunning: Bool
    ) -> CheckInAvailability {
        // An in-flight check-in owns the button regardless of boss state — the
        // re-entry guard already blocks a second run, and reporting needs-boss
        // mid-run would make the control flicker.
        if isRunning {
            return .running
        }
        let trimmed = bossAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || !bossIsUsable {
            return .needsBoss
        }
        return .ready
    }

    /// The tap may run the check-in immediately (only in `.ready`).
    public var canRunNow: Bool {
        self == .ready
    }

    /// The tap should route to the set-up-a-boss flow instead of running (only in
    /// `.needsBoss`) — turning a would-be dead click into a guided next step.
    public var routesToBossSetup: Bool {
        self == .needsBoss
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
        case .needsBoss:
            return "No boss set up yet, so there's no one to check in with. "
                + "Set up a boss to ask what's going on and let it keep work moving."
        }
    }
}
