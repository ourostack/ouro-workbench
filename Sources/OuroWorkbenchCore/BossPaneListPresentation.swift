import Foundation

/// How the boss pane's "Needs Me" / "Coding" columns render their list (#U23c).
/// The columns used to show `prefix(3)` as plain Text and silently drop items
/// 4+. This pure helper decides how many to show vs. when to offer a "View all
/// N" control (so nothing is silently truncated), and derives the navigation key
/// each clickable item jumps by from the ref it already carries.
public struct BossPaneListPresentation: Equatable, Sendable {
    /// How many rows to render inline.
    public var visibleCount: Int
    /// The total number of items, for the "View all N" affordance.
    public var totalCount: Int
    /// Whether there are more items than the inline limit.
    public var hasOverflow: Bool { totalCount > visibleCount }
    /// "View all N" label when there's overflow, else `nil`.
    public var viewAllLabel: String? { hasOverflow ? "View all \(totalCount)" : nil }

    /// Decide the visible/overflow split for `count` items capped at
    /// `visibleLimit`. At or below the limit, everything shows and there's no
    /// overflow; above it, the first `visibleLimit` show with a "View all N".
    public static func make(count: Int, visibleLimit: Int) -> BossPaneListPresentation {
        BossPaneListPresentation(visibleCount: min(count, visibleLimit), totalCount: count)
    }

    /// The navigation key a clickable "Needs Me" item jumps by — the `ref.focus`
    /// it already carries when present and non-blank, else the item's label. So
    /// the row uses the ref the UI used to throw away, with a sensible fallback.
    public static func navigationKey(for item: MailboxNeedsMeItem) -> String {
        if let focus = item.ref?.focus {
            let trimmed = focus.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return item.label
    }
}
