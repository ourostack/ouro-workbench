import Foundation

public struct WorkbenchDefaults: Sendable {
    public var projectName: String
    public var projectRootPath: String
    public var boss: BossAgentSelection
    public var includeLocalShell: Bool

    public init(
        projectName: String = "This Mac",
        projectRootPath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        boss: BossAgentSelection = BossAgentSelection(),
        includeLocalShell: Bool = true
    ) {
        self.projectName = projectName
        self.projectRootPath = projectRootPath
        self.boss = boss
        self.includeLocalShell = includeLocalShell
    }

    public static func firstRunSetup(
        projectRootPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> WorkbenchDefaults {
        WorkbenchDefaults(
            projectName: WorkbenchSurfacePolicy.setupWorkspaceName,
            projectRootPath: projectRootPath,
            boss: BossAgentSelection(),
            includeLocalShell: false
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

        if defaults.includeLocalShell {
            if let existingIndex = next.processEntries.firstIndex(where: { entry in
                entry.projectId == project.id && BuiltInWorkbenchSessions.isLocalShell(entry)
            }) {
                var shell = next.processEntries.remove(at: existingIndex)
                BuiltInWorkbenchSessions.repairLocalShell(&shell, project: project)
                next.processEntries.insert(shell, at: 0)
            } else {
                next.processEntries.insert(
                    BuiltInWorkbenchSessions.localShell(project: project),
                    at: 0
                )
            }
        }

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

public enum BuiltInWorkbenchSessions {
    public static let localShellName = "Local Shell"
    public static let localShellExecutable = "/bin/zsh"
    public static let localShellArguments = ["-l"]

    public static func localShell(project: WorkbenchProject) -> ProcessEntry {
        ProcessEntry(
            projectId: project.id,
            name: localShellName,
            kind: .shell,
            executable: localShellExecutable,
            arguments: localShellArguments,
            workingDirectory: project.rootPath,
            trust: .trusted,
            autoResume: true,
            attention: .idle,
            lastSummary: "Ready local shell"
        )
    }

    public static func isLocalShell(_ entry: ProcessEntry) -> Bool {
        entry.kind == .shell && entry.name == localShellName
    }

    public static func isAutoLaunchableLocalShell(_ entry: ProcessEntry) -> Bool {
        isLocalShell(entry)
            && entry.executable == localShellExecutable
            && entry.arguments == localShellArguments
            && entry.trust == .trusted
            && entry.autoResume
    }

    public static func repairLocalShell(_ entry: inout ProcessEntry, project: WorkbenchProject) {
        entry.name = localShellName
        entry.kind = .shell
        entry.agentKind = nil
        entry.executable = localShellExecutable
        entry.arguments = localShellArguments
        entry.workingDirectory = entry.workingDirectory.isEmpty ? project.rootPath : entry.workingDirectory
        entry.trust = .trusted
        entry.autoResume = true
        if entry.lastSummary == nil {
            entry.lastSummary = "Ready local shell"
        }
    }

    public static func repairTerminalAgentTemplate(
        _ entry: inout ProcessEntry,
        preset: TerminalAgentPreset,
        project: WorkbenchProject
    ) {
        entry.name = preset.displayName
        entry.kind = .terminalAgent
        entry.agentKind = preset.id
        entry.executable = preset.executable
        entry.arguments = entry.trust == .trusted ? preset.yoloArguments : preset.defaultArguments
        entry.workingDirectory = entry.workingDirectory.isEmpty ? project.rootPath : entry.workingDirectory
        if entry.lastSummary == nil || entry.lastSummary?.hasPrefix("Configured ") == true {
            entry.lastSummary = "Configured \(preset.displayName) terminal"
        }
    }
}
