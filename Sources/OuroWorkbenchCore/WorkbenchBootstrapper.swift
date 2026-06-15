import Foundation

public struct WorkbenchDefaults: Sendable {
    public var projectName: String
    public var projectRootPath: String
    public var boss: BossAgentSelection

    public init(
        projectName: String = WorkbenchSurfacePolicy.setupWorkspaceName,
        projectRootPath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        boss: BossAgentSelection = BossAgentSelection()
    ) {
        self.projectName = projectName
        self.projectRootPath = projectRootPath
        self.boss = boss
    }

    public static func firstRunSetup(
        projectRootPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> WorkbenchDefaults {
        WorkbenchDefaults(
            projectName: WorkbenchSurfacePolicy.setupWorkspaceName,
            projectRootPath: projectRootPath,
            boss: BossAgentSelection()
        )
    }
}

public struct WorkbenchBootstrapper: Sendable {
    public init() {}

    public func bootstrappedState(from state: WorkspaceState, defaults: WorkbenchDefaults = WorkbenchDefaults()) -> WorkspaceState {
        var next = state
        // De-duplicate process entries by id (keep the first occurrence). A
        // malformed or torn state file with two entries sharing an id would
        // otherwise trap any consumer that builds `Dictionary(uniqueKeysWithValues:)`
        // keyed on the entry id — crashing the long-lived MCP server. Every load
        // path (app and MCP server) runs through here, so this protects them all.
        next.processEntries = dedupedByID(next.processEntries)
        if next.projects.isEmpty {
            let project = WorkbenchProject(
                name: defaults.projectName,
                rootPath: defaults.projectRootPath,
                boss: defaults.boss
            )
            next.projects = [project]
        }

        if next.boss.agentName.isEmpty {
            next.boss = defaults.boss
        }

        guard let project = next.projects.first else {
            return next
        }

        removeUntouchedLegacyScaffolds(from: &next)

        for index in next.processEntries.indices where next.processEntries[index].kind == .terminalAgent {
            if next.processEntries[index].agentKind == nil {
                next.processEntries[index].agentKind = TerminalAgentDetector.detect(entry: next.processEntries[index])
            }
            if next.processEntries[index].workingDirectory.isEmpty {
                next.processEntries[index].workingDirectory = project.rootPath
            }
        }

        next.updatedAt = Date()
        return next
    }

    /// Returns the entries in order with any duplicate `id` after the first
    /// dropped. Order-preserving so the existing local-shell-at-front and
    /// selection invariants are unaffected for well-formed input.
    private func dedupedByID(_ entries: [ProcessEntry]) -> [ProcessEntry] {
        var seen = Set<UUID>()
        return entries.filter { seen.insert($0.id).inserted }
    }

    private func removeUntouchedLegacyScaffolds(from state: inout WorkspaceState) {
        let removableIDs = Set(
            state.processEntries
                .filter { isUntouchedLegacyScaffold($0, in: state) }
                .map(\.id)
        )
        guard !removableIDs.isEmpty else {
            return
        }

        state.processEntries.removeAll { removableIDs.contains($0.id) }
        if let selectedEntryId = state.selectedEntryId, removableIDs.contains(selectedEntryId) {
            state.selectedEntryId = nil
        }
    }

    private func isUntouchedLegacyScaffold(_ entry: ProcessEntry, in state: WorkspaceState) -> Bool {
        guard !entry.isArchived,
              !state.processRuns.contains(where: { $0.entryId == entry.id }),
              !state.actionLog.contains(where: { $0.targetEntryId == entry.id })
        else {
            return false
        }

        if isLegacyAgentScaffold(entry) || isLegacyDemoAgent(entry) {
            return true
        }
        return false
    }

    private func isLegacyAgentScaffold(_ entry: ProcessEntry) -> Bool {
        TerminalAgentPresets.all.contains { preset in
            entry.kind == .terminalAgent
                && entry.name == preset.displayName
                && (entry.agentKind == preset.id || TerminalAgentDetector.detect(entry: entry) == preset.id)
                && entry.lastSummary == "Configured \(preset.displayName) lane"
        }
    }

    private func isLegacyDemoAgent(_ entry: ProcessEntry) -> Bool {
        entry.kind == .terminalAgent
            && entry.name == "Demo Agent"
            && entry.executable == "/bin/zsh"
            && entry.arguments == ["-lc", "echo hello from demo"]
            && entry.lastSummary == "Custom terminal session: echo hello from demo"
    }
}
