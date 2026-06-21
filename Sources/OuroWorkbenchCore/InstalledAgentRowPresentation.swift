import Foundation

/// U36: the per-status dot color and human-readable reason for an agent row in the
/// empty-state "Installed agents" card.
///
/// The card used to color every non-ready agent with ONE wordless orange dot,
/// collapsing three distinct states (disabled / agent.json missing / invalid
/// config) into a single unreadable alarm with no label, tooltip, or action — even
/// though the per-status repair copy already existed. This pure seam restores the
/// 3-way dot color (matching the sidebar's `SidebarAgentRow`) and supplies a plain
/// reason for each non-ready state, so an intentionally-disabled agent doesn't read
/// as an unexplained error. Framework-free so the rule is unit-testable; the view
/// maps `DotColor` onto a SwiftUI color and renders the reason verbatim.
public enum InstalledAgentRowPresentation {
    /// The row's health dot, framework-free. The view maps `.green → .green`,
    /// `.orange → .orange`, `.red → .red`.
    public enum DotColor: Equatable, Sendable {
        case green
        case orange
        case red
    }

    /// The dot color for a bundle status — identical to `SidebarAgentRow` so the
    /// card and the sidebar never disagree about an agent's health.
    public static func dotColor(for status: OuroAgentBundleStatus) -> DotColor {
        switch status {
        case .ready:
            return .green
        case .disabled, .missingConfig:
            return .orange
        case .invalidConfig:
            return .red
        }
    }

    /// A human-readable reason a non-ready row isn't usable, or `nil` for a ready
    /// agent (which needs no explanation). `detail` is the scanner's raw per-status
    /// detail (`OuroAgentRecord.detail`); the invalid-config reason carries it so
    /// the operator can see exactly what's wrong with the config.
    public static func reason(for status: OuroAgentBundleStatus, detail: String) -> String? {
        switch status {
        case .ready:
            return nil
        case .disabled:
            return "Disabled in agent.json"
        case .missingConfig:
            return "No agent.json — this bundle isn't configured yet"
        case .invalidConfig:
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Invalid agent.json" : "Invalid agent.json — \(trimmed)"
        }
    }
}
