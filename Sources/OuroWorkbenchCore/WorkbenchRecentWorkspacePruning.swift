// STUB (red phase): deliberately wrong so the FIX 3 tests fail at runtime.
public enum WorkbenchRecentWorkspaceLoadFailure: Equatable, Sendable {
    case configMissing
    case malformed
    case empty
    case transient
}

public enum WorkbenchRecentWorkspacePruning {
    public static func shouldForget(after failure: WorkbenchRecentWorkspaceLoadFailure) -> Bool {
        false
    }

    public static func classify(_ error: WorkbenchWorkspaceConfigError) -> WorkbenchRecentWorkspaceLoadFailure {
        .transient
    }
}
