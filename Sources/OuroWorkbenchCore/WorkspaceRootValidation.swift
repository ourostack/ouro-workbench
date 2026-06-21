import Foundation

/// Pure validation for a workspace's root path, shared by the operator's New/Edit
/// Workspace sheets AND the boss's `createGroup` MCP action. The old contract only
/// checked that the path was non-empty, so a typed/pasted bad root path was saved
/// with a green light and became the default working directory for every terminal
/// in that workspace — the only existence check then lived in the per-session launch
/// precheck, displacing a typo made in the form to a per-terminal launch failure with
/// no thread back. For the boss it was worse: createGroup acked success, then every
/// createTerminal into that group failed downstream.
///
/// This expands a leading `~`, then asks an INJECTED existence check whether the
/// expanded path is an existing directory — so the rule is testable without touching
/// the real filesystem.
public enum WorkspaceRootValidation {
    /// What the injected existence check found at a path.
    public enum PathKind: Equatable, Sendable {
        case missing
        case file
        case directory
    }

    public struct Result: Equatable, Sendable {
        public var isUsable: Bool
        /// The tilde-expanded, trimmed path the check ran against (useful for the
        /// caller to persist the standardized form, and for error messages).
        public var expandedPath: String
        /// nil when usable; otherwise a path-specific message the sheet shows inline.
        public var errorMessage: String?

        public init(isUsable: Bool, expandedPath: String, errorMessage: String?) {
            self.isUsable = isUsable
            self.expandedPath = expandedPath
            self.errorMessage = errorMessage
        }
    }

    /// Trims, then expands a LEADING `~` (a `~` anywhere else is a literal). Never
    /// touches the filesystem — pure string work so the existence check stays the
    /// single injectable seam.
    public static func expandedPath(_ rawPath: String, homeDirectory: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("~") else {
            return trimmed
        }
        if trimmed == "~" {
            return homeDirectory
        }
        if trimmed.hasPrefix("~/") {
            let remainder = String(trimmed.dropFirst(2))
            return homeDirectory + "/" + remainder
        }
        // "~name" (another user's home) — leave it to the existence check; we don't
        // resolve foreign homes here.
        return trimmed
    }

    /// Validates a workspace root path: empty → root-required; otherwise expand `~`
    /// and demand the result be an EXISTING directory, naming the offending path when
    /// it isn't. `directoryProbe` is the only FS seam.
    public static func validate(
        _ rawPath: String,
        homeDirectory: String,
        directoryProbe: (String) -> PathKind
    ) -> Result {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Result(
                isUsable: false,
                expandedPath: trimmed,
                errorMessage: WorkbenchSurfacePolicy.workspaceRootPathRequiredMessage
            )
        }
        let expanded = expandedPath(rawPath, homeDirectory: homeDirectory)
        switch directoryProbe(expanded) {
        case .directory:
            return Result(isUsable: true, expandedPath: expanded, errorMessage: nil)
        case .missing:
            return Result(
                isUsable: false,
                expandedPath: expanded,
                errorMessage: "That folder doesn't exist: \(expanded)"
            )
        case .file:
            return Result(
                isUsable: false,
                expandedPath: expanded,
                errorMessage: "That path isn't a folder: \(expanded)"
            )
        }
    }

    /// Convenience boolean for call sites (e.g. SwiftUI `.disabled`) that only need
    /// the verdict, not the message.
    public static func isUsableDirectory(
        _ rawPath: String,
        homeDirectory: String,
        directoryProbe: (String) -> PathKind
    ) -> Bool {
        validate(rawPath, homeDirectory: homeDirectory, directoryProbe: directoryProbe).isUsable
    }

    /// The real-filesystem probe the app and MCP server use as `directoryProbe`.
    /// Kept here (rather than each call site) so the operator's sheet, `createGroup`,
    /// and the boss's MCP `createGroup` all probe identically. Returns `.directory`
    /// only when the path exists AND is a directory.
    public static func fileSystemProbe(_ path: String, fileManager: FileManager = .default) -> PathKind {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing
        }
        return isDirectory.boolValue ? .directory : .file
    }

    /// Validates using the real filesystem (the app/MCP entry point). Home defaults
    /// to the current user's home so a `~` root resolves the same everywhere.
    public static func validateOnDisk(
        _ rawPath: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileManager: FileManager = .default
    ) -> Result {
        validate(rawPath, homeDirectory: homeDirectory) { fileSystemProbe($0, fileManager: fileManager) }
    }
}
