import Foundation

/// Pure name-from-path derivation for the New Workspace sheet (U34). Picking a root
/// folder used to set the path but leave Name empty, so the single most common
/// workspace name — the folder's own basename — always had to be hand-typed and
/// Create sat disabled on first open. This ports the New Terminal sheet's
/// empty-guarded autofill, re-targeted to the path change.
public enum WorkspaceNameDerivation {
    /// The folder basename for a path: its last path component, ignoring trailing
    /// slashes and surrounding whitespace. Returns nil when there is no sensible
    /// basename (empty, whitespace, or the filesystem root "/").
    public static func nameFromPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let last = (trimmed as NSString).lastPathComponent
        // NSString.lastPathComponent returns "/" for the root and "" for an empty
        // string; neither is a usable workspace name.
        guard !last.isEmpty, last != "/" else {
            return nil
        }
        return last
    }

    /// The name to autofill when a root folder is chosen — the path's basename, but
    /// ONLY when the current Name is still empty (never typed, or whitespace). Returns
    /// nil to mean "leave Name as-is": the operator already typed a name, or the path
    /// has no derivable basename. Mirrors the New Terminal sheet's empty-guarded
    /// onChange so a name the operator typed first is never clobbered.
    public static func autofilledName(currentName: String, chosenPath: String) -> String? {
        guard currentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return nameFromPath(chosenPath)
    }
}
