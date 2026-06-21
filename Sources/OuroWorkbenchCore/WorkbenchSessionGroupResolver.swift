import Foundation

/// U29 — the pure get-or-create resolution behind a single `workbench_create_session`
/// call. Today the boss must `createGroup` (and confirm it drained) before it can land
/// a session in a not-yet-existing workspace; this resolver collapses that into one
/// decision so the MCP handler can provision the workspace and the session together.
///
/// Given the requested `group`, the boss's `createGroupIfMissing` intent, and a
/// `rootPath`, the resolver decides one of:
///   - `.existing(project)` — a unique UUID/name match already exists; use it.
///   - `.deferred` — no group was named; the app uses its selected/first group (today's
///     nil-group behaviour).
///   - `.create(name, rootPath)` — the named group is missing AND the boss opted in AND
///     the rootPath is a usable directory (validated per U14); the handler should create
///     the group at this expanded path, then land the session in it.
///   - `.invalid(message)` — opted in to create, but the rootPath is empty/missing/not a
///     directory; the path-specific U14 message says why.
///   - `.mustExist(message)` — the named group is missing/ambiguous and the boss did NOT
///     opt in; the strict, must-already-exist default (today's error), now also pointing
///     at the new opt-in.
///
/// Pure: the only filesystem seam is the injected `directoryProbe`, so every arm is unit
/// tested without touching disk. Reuses `WorkspaceRootValidation` so the create path
/// validates a rootPath identically to the operator's New-Workspace sheet and the boss's
/// `createGroup` MCP action.
public enum WorkbenchSessionGroupResolver {
    /// A group the resolver decided to create: a name plus the tilde-expanded, validated
    /// root path the new workspace should use.
    public struct GroupToCreate: Equatable, Sendable {
        public var name: String
        public var rootPath: String

        public init(name: String, rootPath: String) {
            self.name = name
            self.rootPath = rootPath
        }
    }

    public enum Resolution: Equatable, Sendable {
        case existing(WorkbenchProject)
        case deferred
        case create(name: String, rootPath: String)
        case invalid(String)
        case mustExist(String)

        /// The group to create when this resolution is `.create`, else nil. Lets the MCP
        /// handler build the `createGroup` action without re-destructuring the enum.
        public var groupToCreate: GroupToCreate? {
            guard case let .create(name, rootPath) = self else {
                return nil
            }
            return GroupToCreate(name: name, rootPath: rootPath)
        }
    }

    public static func resolve(
        group: String?,
        createGroupIfMissing: Bool,
        rootPath: String?,
        workspaceState: WorkspaceState,
        homeDirectory: String,
        directoryProbe: (String) -> WorkspaceRootValidation.PathKind
    ) -> Resolution {
        // No group named → the app uses its selected/first group (today's behaviour).
        guard let trimmedGroup = group?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedGroup.isEmpty else {
            return .deferred
        }

        // A unique UUID or case-insensitive name match wins — same matching the strict
        // `resolveGroup` used, so an existing group is reused, never duplicated.
        if let id = UUID(uuidString: trimmedGroup),
           let project = workspaceState.projects.first(where: { $0.id == id }) {
            return .existing(project)
        }
        let nameMatches = workspaceState.projects.filter {
            $0.name.caseInsensitiveCompare(trimmedGroup) == .orderedSame
        }
        if nameMatches.count == 1 {
            return .existing(nameMatches[0])
        }

        // Missing (or ambiguous) and the boss did NOT opt in to create → strict default.
        guard createGroupIfMissing else {
            return .mustExist(mustExistMessage(for: trimmedGroup))
        }
        // An ambiguous name (≥2 matches) is never auto-created — we can't know which the
        // boss meant, so creating a third same-named group would make it worse.
        if nameMatches.count > 1 {
            return .mustExist(mustExistMessage(for: trimmedGroup))
        }

        // Opted in to create: the rootPath must be a usable directory (validated per U14).
        // An empty/absent rootPath can't create a workspace — reject with the same
        // root-required message the operator's New-Workspace sheet shows, BEFORE the
        // existence check, so the resolver never has to surface a nil validation message.
        let rawRoot = (rootPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawRoot.isEmpty else {
            return .invalid(WorkbenchSurfacePolicy.workspaceRootPathRequiredMessage)
        }
        let validation = WorkspaceRootValidation.validate(
            rawRoot,
            homeDirectory: homeDirectory,
            directoryProbe: directoryProbe
        )
        // The rootPath is non-empty here, so `validate` returns EITHER usable (no message)
        // OR a concrete path-specific rejection message ("doesn't exist" / "isn't a
        // folder") — the two arms below are exactly those two outcomes, no dead fallback.
        if let errorMessage = validation.errorMessage {
            return .invalid(errorMessage)
        }
        return .create(name: trimmedGroup, rootPath: validation.expandedPath)
    }

    /// The strict must-already-exist message — today's `resolveGroup` text, extended to
    /// point at the new one-call opt-in so the boss learns it can provision in place.
    private static func mustExistMessage(for group: String) -> String {
        "No unique group matches \(group). Create it first via workbench_request_action (createGroup), or pass createGroupIfMissing with a workingDirectory."
    }
}
