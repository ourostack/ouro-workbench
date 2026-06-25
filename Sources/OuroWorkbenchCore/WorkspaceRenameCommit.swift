import Foundation

/// Slice ②d — D2d-1: the pure decision for what an inline-rename COMMIT does, shared
/// by the workspace rename and the tab rename (same rule for `nameOverride` and
/// `tabNameOverride`). Extracted out of the SwiftUI closure so the empty/whitespace
/// semantics are unit-tested, not buried in a view.
///
/// The decision:
/// - An EMPTY or whitespace-only input is a **no-op** (`.noop`): the editor closes and
///   the name is UNCHANGED — it neither writes a blank override (a footgun: a blank row)
///   nor reverts to auto (revert has its OWN explicit "Remove Custom Workspace Name"
///   affordance, so a blank commit must not silently mean it).
/// - A non-empty input is **trimmed** of leading/trailing whitespace and committed.
/// - If the trimmed value EQUALS `current` it is also a `.noop` (no spurious override
///   write / no needless save).
///
/// NOTE: the MODEL still honors an empty override if one is set programmatically (②a
/// DA4, covered by `WorkspaceStructureTests`). This helper only prevents the EDITOR
/// from PRODUCING one.
public enum WorkspaceRenameCommit {
    /// The outcome of resolving a rename-commit input against the current name.
    public enum Outcome: Equatable, Sendable {
        /// Apply this (already-trimmed, non-empty, changed) value as the override.
        case commit(String)
        /// Do nothing — the editor closes and the name is unchanged (empty/whitespace
        /// input, or a trimmed value equal to `current`).
        case noop
    }

    /// Decide what a rename commit does (D2d-1). `input` is the raw editor text;
    /// `current` is the name the editor was prefilled with (`effectiveName` /
    /// `effectiveTabName`). Pure — same inputs always give the same outcome.
    public static func resolve(input: String, current: String) -> Outcome {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .noop
        }
        guard trimmed != current else {
            return .noop
        }
        return .commit(trimmed)
    }
}
