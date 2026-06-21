import Foundation

/// Copy for the main-window empty state (`AgentHomeEmptyState`), reframed terminals-first by the
/// subtractive FRE redesign. The six-word story is the cut-test: "Your terminals. An agent runs
/// them." The old copy led boss-first ("Set up Workbench / Choose a boss agent…") with the
/// terminal buried as the third button; the new hierarchy leads with purpose + `New Terminal`
/// (the primary, gate-free action) and makes the boss a secondary opt-in.
///
/// Kept in Core so the message is pinned by unit tests rather than buried as App-target view
/// literals — the `AgentHomeEmptyState` view renders these verbatim.
public enum AgentHomeEmptyStateCopy {
    /// Leads with purpose, not a setup demand.
    public static let headline = "Your terminals. An agent runs them."

    /// Frames the boss as optional: instant utility now, a boss when you want one.
    public static let subtext = "Your terminal agents stay real terminals — open one and go. When you "
        + "want a boss watching the whole Mac and keeping work moving, set one up. No setup "
        + "required to start."

    /// Primary, gate-free action — `.borderedProminent` in the view.
    public static let newTerminalButton = "New Terminal"

    /// Secondary opt-in that opens the (now opt-in) boss wizard via `presentOnboarding()`.
    public static let setUpBossButton = "Set up a boss"

    /// Lowest-weight action — create a new agent. U18: leads with plain language a
    /// newcomer can parse (no bare "hatch"/"bundle"); the Ouro "hatch" flavor is glossed
    /// once in the help. Opens the native "Create your agent" form (name + provider +
    /// credentials), NOT a raw `ouro hatch` CLI pane.
    public static let createAgentButton = "Create an Agent"

    /// One-line "why" for the create action — glosses the Ouro "hatch" flavor on first
    /// encounter so the label is legible to someone who's never used Ouro.
    public static let createAgentHelp =
        "Create a new Ouro agent (\u{201C}hatch\u{201D}) — name it, pick a provider, and add credentials."
}
