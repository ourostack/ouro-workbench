import Foundation

/// Direction used by the Workbench's terminal/group cycling keyboard
/// shortcuts. Lives in Core so view-model helpers and tests can reference it
/// without importing AppKit.
public enum WorkbenchCycleDirection: String, Codable, Equatable, Sendable {
    /// Move toward the start of the list (⌘[).
    case previous
    /// Move toward the end of the list (⌘]).
    case next
}
