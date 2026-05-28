import Foundation

/// A small fixed palette of accent colors a user can assign to a group so
/// the sidebar is scannable at a glance. Stored as a raw string on
/// `WorkbenchProject.colorTag` (nil / absent = no tag, renders neutral).
///
/// Kept in the core module — and as a plain string list rather than a
/// SwiftUI `Color` — so the model layer has no UI dependency. The app layer
/// maps each case to a concrete `Color`.
public enum WorkbenchGroupColor: String, CaseIterable, Identifiable, Sendable {
    case gray
    case blue
    case green
    case orange
    case red
    case purple
    case pink
    case teal

    public var id: String { rawValue }

    /// Human-facing label for the color picker.
    public var label: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    /// Parse a stored tag string into a known color. Unknown / nil values
    /// fall back to `nil` so a future-added color in a newer build doesn't
    /// crash an older one — it just renders untagged.
    public static func from(tag: String?) -> WorkbenchGroupColor? {
        guard let tag else { return nil }
        return WorkbenchGroupColor(rawValue: tag)
    }
}
