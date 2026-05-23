import Foundation

public struct WorkbenchDefaults: Sendable {
    public var projectName: String
    public var projectRootPath: String
    public var boss: BossAgentSelection
    public var trustP0AgentLanes: Bool
    public var autoResumeP0AgentLanes: Bool

    public init(
        projectName: String = "This Mac",
        projectRootPath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        boss: BossAgentSelection = BossAgentSelection(),
        trustP0AgentLanes: Bool = true,
        autoResumeP0AgentLanes: Bool = true
    ) {
        self.projectName = projectName
        self.projectRootPath = projectRootPath
        self.boss = boss
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

        for preset in TerminalAgentPresets.all {
            let alreadyConfigured = next.processEntries.contains { entry in
                entry.projectId == project.id && entry.kind == .terminalAgent && entry.agentKind == preset.id
            }
            if alreadyConfigured {
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
