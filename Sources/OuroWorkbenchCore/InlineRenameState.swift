import Foundation

/// Slice ②d — the pure, framework-free state for the inline rename editor (D2d-3:
/// inline `TextField`, not a sheet). One value serves BOTH the workspace context menu
/// and the tab context menu: the App holds a single `@Published var inlineRename` and
/// each row/tab swaps its label for the editor when `isEditing(target:)` is true.
///
/// Kept SwiftUI-free so it is XCTest-visible and 100%-coverage-gated; the App binds the
/// editor's `TextField` text to `draft` and routes `commit()`'s result through
/// `WorkspaceRenameCommit` (D2d-1) to the per-target mutator.
public struct InlineRenameState: Equatable, Sendable {
    /// What is being renamed. `.workspace`/`.tab` carry the entity id; the same UUID
    /// under a different kind is a DIFFERENT target (so a workspace and a tab that
    /// happened to share an id can't be confused).
    public enum Target: Equatable, Sendable {
        case workspace(UUID)
        case tab(UUID)
    }

    /// The pending commit handed back to the caller: which target was being edited and
    /// the raw draft input (the caller resolves it through `WorkspaceRenameCommit`).
    public struct PendingCommit: Equatable, Sendable {
        public let target: Target
        public let input: String

        public init(target: Target, input: String) {
            self.target = target
            self.input = input
        }
    }

    /// The active rename target, or `nil` when no editor is open.
    public private(set) var target: Target?

    /// The editor's draft text. Bound to the `TextField` while a target is active;
    /// always `""` when inactive (set/cleared by `begin`/`cancel`/`commit`).
    public var draft: String

    public init() {
        self.target = nil
        self.draft = ""
    }

    /// Open the editor for `target`, prefilled with `prefill` (the current
    /// `effectiveName`/`effectiveTabName`). Beginning while another target is active
    /// SWITCHES target and REPLACES the draft — no stale text from the previous edit
    /// leaks in.
    public mutating func begin(target: Target, prefill: String) {
        self.target = target
        self.draft = prefill
    }

    /// Close the editor without committing: deactivate and clear the draft (so the next
    /// `begin` starts from its own prefill, never leftover text).
    public mutating func cancel() {
        self.target = nil
        self.draft = ""
    }

    /// Commit the current edit: return the active target + draft for the caller to
    /// resolve through `WorkspaceRenameCommit`, then go inactive (and clear the draft).
    /// Returns `nil` when no target is active (nothing to commit).
    public mutating func commit() -> PendingCommit? {
        guard let target else {
            return nil
        }
        let pending = PendingCommit(target: target, input: draft)
        self.target = nil
        self.draft = ""
        return pending
    }

    /// Whether the editor is currently open for exactly `target` — the row/tab uses this
    /// to decide whether to render the editor or its label.
    public func isEditing(_ candidate: Target) -> Bool {
        target == candidate
    }
}
