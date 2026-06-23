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
    /// `.workbench.json` couldn't be read or parsed (the loader maps both an
    /// unreadable file and invalid JSON to this — structurally dead either way).
    case malformed
    /// `.workbench.json` parsed but declared no terminals (structurally useless).
    case empty
    /// An unexpected / non-structural failure (the generic catch). May clear on a
    /// retry, so the recent is KEPT.
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

    /// Classify a typed `WorkbenchWorkspaceConfigError` into a load-failure. Every
    /// typed config error is STRUCTURAL (the transient arm is reachable only from
    /// the App's generic catch, which maps to `.transient` directly).
    public static func classify(_ error: WorkbenchWorkspaceConfigError) -> WorkbenchRecentWorkspaceLoadFailure {
        switch error {
        case .configFileMissing:
            return .configMissing
        case .malformedJSON:
            return .malformed
        case .noTerminals:
            return .empty
        }
    }
}
