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

    // MARK: - Live readiness (honest steady-state seam)

    /// The LIVE readiness of an agent row — the scanner's CONFIG-ONLY
    /// `OuroAgentBundleStatus` folded together with the result of an actual
    /// `ouro check` (a `ProviderConnectionVerdict?`) and an in-flight flag.
    ///
    /// The bug this replaces: the steady-state sidebar / "Installed agents" rows
    /// rendered the scanner's `.ready` (which only means "agent.json present &
    /// enabled") as a green "ready" dot + tooltip, WITHOUT ever running a live
    /// connection check — a false green (slugger reads "ready" while `ouro check`
    /// returns `failed (401 … expired)`). `LiveReadiness` never reports `.ready`
    /// (the only green state) unless a live check actually returned `.working`.
    public enum LiveReadiness: Equatable, Sendable {
        /// Live check returned `working`. The ONLY green state.
        case ready
        /// A live check is in flight; we don't yet know the answer.
        case checking
        /// Live check returned `unauthorized` (e.g. a 401 / expired token).
        case authExpired
        /// Live check returned `vaultLocked` (credentials present but locked).
        case vaultLocked
        /// Live check returned `unreachable` (network / provider down).
        case unreachable
        /// Config says ready but no live check has confirmed it (no verdict yet,
        /// none in flight) — or the verdict was indeterminate. NOT green.
        case unverified
        /// `agent.json` disables this agent.
        case disabled
        /// No `agent.json` for this bundle.
        case missingConfig
        /// `agent.json` is present but malformed.
        case invalidConfig
    }

    /// Resolve the honest live readiness for a row.
    ///
    /// HONESTY INVARIANT (resolution order):
    ///   1. Config problems dominate — a disabled / missing / invalid bundle can't be
    ///      "ready" no matter what a stale verdict says.
    ///   2. Otherwise, if we have a live verdict, it decides
    ///      (`.working→.ready`, `.unauthorized→.authExpired`, `.vaultLocked→.vaultLocked`,
    ///      `.unreachable→.unreachable`, `.indeterminate→.unverified`).
    ///   3. Otherwise, if a live check is in flight → `.checking`.
    ///   4. Otherwise → `.unverified` (config-only `.ready` is NEVER reported as
    ///      `.ready`/green without a confirming live verdict).
    public static func liveReadiness(
        status: OuroAgentBundleStatus,
        verdict: ProviderConnectionVerdict?,
        isChecking: Bool
    ) -> LiveReadiness {
        // 1. Config problems dominate.
        switch status {
        case .disabled:
            return .disabled
        case .missingConfig:
            return .missingConfig
        case .invalidConfig:
            return .invalidConfig
        case .ready:
            break
        }
        // 2. A live verdict, if present, decides.
        if let verdict {
            switch verdict {
            case .working:
                return .ready
            case .unauthorized:
                return .authExpired
            case .vaultLocked:
                return .vaultLocked
            case .unreachable:
                return .unreachable
            case .indeterminate:
                return .unverified
            }
        }
        // 3. A check is in flight.
        if isChecking {
            return .checking
        }
        // 4. Config-only ready, no live confirmation → unverified (never a false green).
        return .unverified
    }

    /// The health dot for a live readiness. GREEN is reserved for `.ready` alone
    /// (the only state produced exclusively by a `.working` live verdict); RED for
    /// `.invalidConfig`; ORANGE for every other state (checking, auth-expired,
    /// vault-locked, unreachable, unverified, disabled, missing config).
    public static func dotColor(for readiness: LiveReadiness) -> DotColor {
        switch readiness {
        case .ready:
            return .green
        case .invalidConfig:
            return .red
        case .checking, .authExpired, .vaultLocked, .unreachable, .unverified, .disabled, .missingConfig:
            return .orange
        }
    }

    /// A short, glanceable label for a live readiness — distinct per state.
    public static func label(for readiness: LiveReadiness) -> String {
        switch readiness {
        case .ready:
            return "ready"
        case .checking:
            return "checking…"
        case .authExpired:
            return "sign-in needed"
        case .vaultLocked:
            return "credentials locked"
        case .unreachable:
            return "can't reach provider"
        case .unverified:
            return "not verified"
        case .disabled:
            return "disabled"
        case .missingConfig:
            return "no config"
        case .invalidConfig:
            return "bad config"
        }
    }

    /// The SF Symbol name for a live readiness — the SHARED-SEAM icon decision so the
    /// agent detail pane (`AgentStatusCard.statusIcon`) and the empty-state row
    /// (`OuroAgentRowView.agentStatusImage`) pick the SAME glyph, and pick it off the
    /// LIVE readiness rather than raw config `agent.status`.
    ///
    /// HONESTY INVARIANT: the SUCCESS glyph (`checkmark.seal.fill`) is reachable ONLY
    /// from `.ready` (the sole state a `.working` live verdict produces) — an
    /// expired-token agent (config-`.ready`, live `.authExpired`) never wears the seal.
    /// CALM-NOT-LOUD: pending states (`.checking`, `.unverified`) get neutral glyphs
    /// (`ellipsis.circle` / `questionmark.circle`), never the warning triangle — only
    /// CONFIRMED-bad verdicts (`.authExpired` / `.vaultLocked` / `.unreachable`) do.
    public static func iconSystemName(for readiness: LiveReadiness) -> String {
        switch readiness {
        case .ready:
            return "checkmark.seal.fill"
        case .checking:
            return "ellipsis.circle"
        case .unverified:
            return "questionmark.circle"
        case .authExpired, .vaultLocked, .unreachable:
            return "exclamationmark.triangle.fill"
        case .disabled:
            return "pause.circle.fill"
        case .missingConfig, .invalidConfig:
            return "xmark.octagon.fill"
        }
    }

    /// The PROMINENT card title for the agent detail pane (`AgentStatusCard.statusHeadline`).
    ///
    /// HONESTY INVARIANT: the word "ready" (and the title "Bundle ready") is reachable
    /// ONLY from `.ready` — the sole state a `.working` live verdict produces. The bug
    /// this replaces: the card headline switched on raw config `agent.status` and read
    /// "Bundle ready" for a config-`.ready` agent even when its live verdict was
    /// `.authExpired`, so an expired-token agent's title said "Bundle ready" next to an
    /// honest "sign-in needed" pill. Live states get an honest title; the config-problem
    /// states (`.disabled` / `.missingConfig` / `.invalidConfig`) keep the bundle-config
    /// wording — those ARE config truths — and `.invalidConfig` embeds the raw `detail`.
    public static func headline(for readiness: LiveReadiness, detail: String) -> String {
        switch readiness {
        case .ready:
            return "Bundle ready"
        case .checking:
            return "Checking connection…"
        case .unverified:
            return "Not verified yet"
        case .authExpired:
            return "Sign-in needed"
        case .vaultLocked:
            return "Credentials locked"
        case .unreachable:
            return "Provider unreachable"
        case .disabled:
            return "Bundle disabled in agent.json"
        case .missingConfig:
            return "Bundle missing agent.json"
        case .invalidConfig:
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Bundle config could not be read" : "Bundle config could not be read — \(trimmed)"
        }
    }

    /// A fuller tooltip for a live readiness. `detail` is the scanner's raw per-status
    /// detail; the `.invalidConfig` tooltip embeds it so the operator can see exactly
    /// what's malformed.
    public static func help(for readiness: LiveReadiness, detail: String) -> String {
        switch readiness {
        case .ready:
            return "Ready — a live connection check just succeeded."
        case .checking:
            return "Checking this agent's provider connection…"
        case .authExpired:
            return "Sign-in needed — the provider rejected the credentials (expired or invalid). Reconnect this agent."
        case .vaultLocked:
            return "Credentials are locked — unlock the vault so this agent can reach its provider."
        case .unreachable:
            return "Can't reach the provider — the network or the provider is down. Try again."
        case .unverified:
            return "Not verified — its config looks ready, but no live connection check has confirmed it yet."
        case .disabled:
            return "Disabled in agent.json."
        case .missingConfig:
            return "No agent.json — this bundle isn't configured yet."
        case .invalidConfig:
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Invalid agent.json." : "Invalid agent.json — \(trimmed)"
        }
    }
}
