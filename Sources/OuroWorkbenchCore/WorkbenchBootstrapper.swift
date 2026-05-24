import Foundation

public struct WorkbenchDefaults: Sendable {
    public var projectName: String
    public var projectRootPath: String
    public var boss: BossAgentSelection
    public var includeLocalShell: Bool
    public var trustP0AgentLanes: Bool
    public var autoResumeP0AgentLanes: Bool

    public init(
        projectName: String = "This Mac",
        projectRootPath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        boss: BossAgentSelection = BossAgentSelection(),
        includeLocalShell: Bool = true,
        trustP0AgentLanes: Bool = true,
        autoResumeP0AgentLanes: Bool = true
    ) {
        self.projectName = projectName
        self.projectRootPath = projectRootPath
        self.boss = boss
        self.includeLocalShell = includeLocalShell
        self.trustP0AgentLanes = trustP0AgentLanes
        self.autoResumeP0AgentLanes = autoResumeP0AgentLanes
    }
}

public struct WorkbenchBootstrapper: Sendable {
    public init() {}

    public func bootstrappedState(from state: WorkspaceState, defaults: WorkbenchDefaults = WorkbenchDefaults()) -> WorkspaceState {
        var next = state
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

        for preset in TerminalAgentPresets.all {
            if let existingIndex = next.processEntries.firstIndex(where: { entry in
                entry.projectId == project.id && entry.kind == .terminalAgent && entry.agentKind == preset.id
            }) {
                BuiltInWorkbenchSessions.repairTerminalAgentLane(
                    &next.processEntries[existingIndex],
                    preset: preset,
                    project: project
                )
                continue
            }

            next.processEntries.append(
                ProcessEntry(
                    projectId: project.id,
                    name: preset.displayName,
                    kind: .terminalAgent,
                    agentKind: preset.id,
                    executable: preset.executable,
                    arguments: defaults.trustP0AgentLanes ? preset.yoloArguments : preset.defaultArguments,
                    workingDirectory: project.rootPath,
                    trust: defaults.trustP0AgentLanes ? .trusted : .untrusted,
                    autoResume: defaults.autoResumeP0AgentLanes,
                    attention: .idle,
                    lastSummary: "Configured \(preset.displayName) lane"
                )
            )
        }

        next.updatedAt = Date()
        return next
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

    public static func repairTerminalAgentLane(
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
            entry.lastSummary = "Configured \(preset.displayName) lane"
        }
    }
}
