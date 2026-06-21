import Foundation

/// Calm-vs-loud presentation for the first-run header (the boss selector dot/label and the TTFA
/// pill). Driven by the subtractive-FRE redesign: a brand-new first run has **no boss chosen yet**
/// (empty `agentName`) — that is EXPECTED, not a failure, so the header must read CALM/neutral.
/// Only once a boss IS named but broken (named-but-not-installed, or an invalid config) is there a
/// REAL problem worth shouting about — that stays LOUD (red), exactly as before.
///
/// The bug this fixes: the two states were conflated. "No boss yet" was rendered with the same red
/// `Boss: <empty>` + "missing" pill + red `TTFA · blocked` as a genuinely broken boss, alarming the
/// user before they'd chosen to set anything up.
///
/// This is a pure, framework-free seam (Core has no SwiftUI) so the decision is unit-testable. The
/// `BossSelectorView` / `AutonomyStatusButton` header views map `BossDotColor` / `TtfaPillStyle`
/// onto `SwiftUI.Color` and render the text/help verbatim.
public enum HeaderCalmPresentation {
    /// The boss health dot color, expressed framework-free. The view maps these onto SwiftUI colors:
    /// `.neutral → .secondary`, `.green → .green`, `.orange → .orange`, `.red → .red`.
    public enum BossDotColor: Equatable, Sendable {
        case neutral
        case green
        case orange
        case red
    }

    /// The TTFA pill style. `.neutral` renders gray (no boss yet — autonomy is simply *off*, not
    /// *blocked*); `.real` renders the live `AutonomyReadinessState` tint (a boss is set, so the
    /// readiness state is meaningful and shown exactly as today).
    public enum TtfaPillStyle: Equatable, Sendable {
        case neutral
        case real
    }

    public struct Presentation: Equatable, Sendable {
        public var bossLabelText: String
        public var bossDotColor: BossDotColor
        public var bossShowsMissingPill: Bool
        public var bossHelp: String
        public var ttfaText: String
        public var ttfaStyle: TtfaPillStyle
        public var ttfaHelp: String

        public init(
            bossLabelText: String,
            bossDotColor: BossDotColor,
            bossShowsMissingPill: Bool,
            bossHelp: String,
            ttfaText: String,
            ttfaStyle: TtfaPillStyle,
            ttfaHelp: String
        ) {
            self.bossLabelText = bossLabelText
            self.bossDotColor = bossDotColor
            self.bossShowsMissingPill = bossShowsMissingPill
            self.bossHelp = bossHelp
            self.ttfaText = ttfaText
            self.ttfaStyle = ttfaStyle
            self.ttfaHelp = ttfaHelp
        }
    }

    /// Calm help shown when no boss is chosen yet.
    public static let noBossYetBossHelp =
        "No boss set yet — pick one to let an Ouro agent watch this Mac and keep work moving."

    /// Calm help on the TTFA pill when no boss is chosen yet.
    public static let noBossYetTtfaHelp = "Set up a boss to enable hands-off operation."

    /// Resolve the header presentation.
    ///
    /// - Parameters:
    ///   - bossAgentName: `model.state.boss.agentName` — empty/whitespace means "no boss chosen yet".
    ///   - bossAgentStatus: the resolved boss bundle status (`model.ouroAgent(named:)?.status`), or
    ///     `nil` when the name doesn't resolve to an installed bundle. When the name is named-but-nil
    ///     the boss is genuinely missing (loud).
    ///   - autonomyState: the live `autonomyReadiness.state`, rendered as-is only when a boss is set.
    ///   - installedBossHelp: the help string to use when the boss IS installed (the caller passes
    ///     the agent record's `"name: detail"` line). Ignored for the empty / missing cases.
    public static func resolve(
        bossAgentName: String,
        bossAgentStatus: OuroAgentBundleStatus?,
        autonomyState: AutonomyReadinessState,
        installedBossHelp: String = ""
    ) -> Presentation {
        let trimmedName = bossAgentName.trimmingCharacters(in: .whitespacesAndNewlines)

        // No boss chosen yet — EXPECTED on first run. Everything calm/neutral.
        if trimmedName.isEmpty {
            return Presentation(
                bossLabelText: "No boss yet",
                bossDotColor: .neutral,
                bossShowsMissingPill: false,
                bossHelp: noBossYetBossHelp,
                ttfaText: "TTFA · off",
                ttfaStyle: .neutral,
                ttfaHelp: noBossYetTtfaHelp
            )
        }

        // A boss IS named — the TTFA pill reflects real readiness, loud or not.
        let ttfaText = "TTFA · \(autonomyState.headerDisplayName)"
        let ttfaHelp =
            "\(AutonomyReadinessSnapshot.headerHelpHeadline(for: autonomyState)). "
                + "Click to open the autonomy readiness checklist."

        // Named but not installed — a genuinely broken boss. Loud red + "missing" pill, as today.
        guard let bossAgentStatus else {
            return Presentation(
                bossLabelText: "Boss: \(bossAgentName)",
                bossDotColor: .red,
                bossShowsMissingPill: true,
                bossHelp: "\(bossAgentName) is the selected boss but isn't installed on this "
                    + "machine. Pick an installed agent or create one.",
                ttfaText: ttfaText,
                ttfaStyle: .real,
                ttfaHelp: ttfaHelp
            )
        }

        // Named AND installed — keep today's per-status colors. No "missing" pill (it IS installed).
        return Presentation(
            bossLabelText: "Boss: \(bossAgentName)",
            bossDotColor: bossAgentStatus.headerDotColor,
            bossShowsMissingPill: false,
            bossHelp: installedBossHelp,
            ttfaText: ttfaText,
            ttfaStyle: .real,
            ttfaHelp: ttfaHelp
        )
    }
}

private extension OuroAgentBundleStatus {
    /// The boss health dot color for an installed bundle — unchanged from the prior inline mapping.
    var headerDotColor: HeaderCalmPresentation.BossDotColor {
        switch self {
        case .ready:
            return .green
        case .disabled, .missingConfig:
            return .orange
        case .invalidConfig:
            return .red
        }
    }
}

private extension AutonomyReadinessState {
    /// The short pill label ("ready" / "watch" / "blocked"). Mirrors the App-target `displayName`
    /// extension; pulled into Core so the calm/loud seam can build the full pill text without
    /// reaching into the App target.
    var headerDisplayName: String {
        switch self {
        case .ready:
            return "ready"
        case .attention:
            return "watch"
        case .blocked:
            return "blocked"
        }
    }
}

private extension AutonomyReadinessSnapshot {
    /// The help headline for a given readiness state — same wording the live snapshot produces, so
    /// the loud TTFA help reads identically to today.
    static func headerHelpHeadline(for state: AutonomyReadinessState) -> String {
        switch state {
        case .ready:
            return "Boss is clear to run"
        case .attention:
            return "Autonomy is usable with watch points"
        case .blocked:
            return "Human-free operation is blocked"
        }
    }
}
