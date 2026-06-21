import Foundation

/// Copy for the Choose Boss onboarding page, keyed on an agent's installed-bundle status.
///
/// HONESTY CONTRACT: at Choose Boss the only thing actually known about an agent is its bundle
/// status — whether it's installed/enabled on this Mac. Whether it can really act as a boss
/// (its provider connections work) is EARNED on the very next page, where `ouro check` runs.
/// So the `.ready` case must not claim connection-readiness here: the label reads "installed"
/// (a real, true state — the badge stays green) and the detail promises the check rather than
/// asserting the boss is good to go. The other statuses are unchanged.
///
/// Pure and in Core so the strings are pinned by tests; the App `OnboardingBossChoice` and
/// `onboardingBossChoices` render these verbatim. This intentionally does NOT touch the
/// `OuroAgentBundleStatus` enum or the empty-state "Installed agents" dot.
public enum OnboardingBossChoiceCopy {
    /// The compact status badge label. `.ready` → "installed" (true at this point), not "ready"
    /// (which would over-claim a connection that hasn't been checked yet).
    public static func statusLabel(for status: OuroAgentBundleStatus) -> String {
        switch status {
        case .ready:
            return "installed"
        case .disabled:
            return "turned off"
        case .missingConfig, .invalidConfig:
            return "needs setup"
        }
    }

    /// The first-grade-simple readiness line. `.ready` promises the next-page connection check
    /// rather than asserting the boss is ready to go.
    public static func detail(for status: OuroAgentBundleStatus) -> String {
        switch status {
        case .ready:
            return "Installed on this Mac. We'll check its connection next."
        case .disabled:
            return "Turned off right now."
        case .missingConfig, .invalidConfig:
            return "Needs a little setup first."
        }
    }
}
