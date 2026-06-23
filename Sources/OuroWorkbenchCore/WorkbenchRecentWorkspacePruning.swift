/// Pure decision for FIX 3 — whether opening a recent workspace that FAILED to
/// load should drop (forget) that recent from the recents menu.
///
/// The bug: `openWorkspaceConfig(at:)` pruned the dead recent ONLY on
/// `configFileMissing`. On `malformedJSON`, `noTerminals`, and the generic catch
/// the broken entry stayed in the menu and re-errored on every click. This seam
/// makes the prune-or-keep choice a framework-free, exhaustively-tested decision:
///
///   - STRUCTURAL failures (the file is gone / unparseable / unreadable / empty)
///     are not going to fix themselves on a retry — the recent is dead, so prune
///     it so the menu stops re-erroring.
///   - A TRANSIENT / unknown failure (the generic catch — e.g. a momentary IO
///     blip a retry might clear) must NOT silently drop the recent: keep it.
public enum WorkbenchRecentWorkspaceLoadFailure: Equatable, Sendable {
    /// `.workbench.json` no longer exists at the recent path.
    case configMissing
    /// `.workbench.json` parsed-as-bytes but was invalid JSON — a genuine
    /// structural failure (a retry won't fix bad JSON). Maps from the loader's
    /// `.malformedJSON`. A FILE-READ failure is NO LONGER lumped here: the loader
    /// emits a distinct `.fileUnreadable`, which classifies as `.transient` (kept).
    case malformed
    /// `.workbench.json` parsed but declared no terminals (structurally useless).
    case empty
    /// A RECOVERABLE failure that a retry may clear: a file-READ blip
    /// (`.fileUnreadable` — momentary lock, EACCES, network-volume hiccup, EIO)
    /// OR the App's generic catch (an unexpected / non-structural error). The
    /// recent is KEPT — we must never silently drop a good workspace on a blip.
    case transient
}

public enum WorkbenchRecentWorkspacePruning {
    /// `true` ⇒ forget the recent (structural failure); `false` ⇒ keep it
    /// (transient / recoverable failure).
    public static func shouldForget(after failure: WorkbenchRecentWorkspaceLoadFailure) -> Bool {
        switch failure {
        case .configMissing, .malformed, .empty:
            return true
        case .transient:
            return false
        }
    }

    /// Classify a typed `WorkbenchWorkspaceConfigError` into a load-failure. The
    /// STRUCTURAL typed errors (missing / bad JSON / empty) map to prune; the lone
    /// recoverable typed error — `.fileUnreadable`, a file-READ blip — maps to
    /// `.transient` (KEEP), so a momentary read failure never drops a good
    /// workspace. (The App's generic catch also maps to `.transient` directly.)
    public static func classify(_ error: WorkbenchWorkspaceConfigError) -> WorkbenchRecentWorkspaceLoadFailure {
        switch error {
        case .configFileMissing:
            return .configMissing
        case .fileUnreadable:
            return .transient
        case .malformedJSON:
            return .malformed
        case .noTerminals:
            return .empty
        }
    }
}
