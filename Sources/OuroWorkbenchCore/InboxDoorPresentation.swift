import Foundation

/// The open-inbox "door" (#U22). The boss pane showed the open-escalation count
/// as a plain, non-interactive chip, while the `DecisionInboxSheet` — the
/// auditable-trust centerpiece — was reachable ONLY via ⌘K / ⌘J. An operator who
/// saw "inbox: 2" had no door: an alarming number with nothing to click.
///
/// This pure presentation answers "is there anything waiting, and how loud is
/// it" so the boss-pane pill ("N waiting on you →"), the tappable "inbox" chip,
/// and the collapsed-pane count badge all share one derivation — and so a
/// zero-count case resolves to `nil` (calm/absent), making a dead zero-count
/// button impossible to render.
public struct InboxDoorPresentation: Equatable, Sendable {
    /// How many decisions are open in the inbox right now (always ≥ 1 — a zero
    /// count resolves to `nil`, never a door with count 0).
    public var count: Int
    /// The severity of the most urgent open group, for the door's tint.
    public var topSeverity: DecisionSeverity

    /// "N waiting on you" — the pill label (the trailing arrow is the view's).
    public var label: String { "\(count) waiting on you" }

    /// Compact count for the collapsed-pane badge.
    public var badgeText: String { "\(count)" }

    /// Spoken affordance — names the count and the destination.
    public var accessibilityLabel: String {
        "\(count) decision\(count == 1 ? "" : "s") waiting on you — open the Decision Inbox"
    }

    /// Tooltip inviting the click.
    public var help: String {
        "Open the Decision Inbox to see and triage what the boss escalated."
    }

    /// Resolve the door from the open inbox at `now`. Returns `nil` when nothing
    /// is open, so callers render no affordance rather than a dead zero-count
    /// button. Otherwise the count and the top group's severity drive the pill.
    public static func resolve(state: WorkspaceState, now: Date = Date()) -> InboxDoorPresentation? {
        let open = state.openInbox(now: now)
        guard let topSeverity = open.map(DecisionSeverity.of).max() else {
            return nil
        }
        return InboxDoorPresentation(count: open.count, topSeverity: topSeverity)
    }
}
