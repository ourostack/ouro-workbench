import Foundation

public enum CommandPlanningError: Error, Equatable, Sendable {
    case unknownTerminalAgentPreset(TerminalAgentKind)
    case missingSessionId(entryName: String)
}

public struct TerminalCommandPlan: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var entryId: UUID
    public var runId: UUID
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String
    public var transcriptPath: String?
    public var recoveryAction: RecoveryAction?
    public var reason: String

    public init(
        id: UUID = UUID(),
        entryId: UUID,
        runId: UUID = UUID(),
        executable: String,
        arguments: [String],
        workingDirectory: String,
        transcriptPath: String? = nil,
        recoveryAction: RecoveryAction? = nil,
        reason: String
    ) {
        self.id = id
        self.entryId = entryId
        self.runId = runId
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.transcriptPath = transcriptPath
        self.recoveryAction = recoveryAction
        self.reason = reason
    }

    public var displayCommand: String {
        ([executable] + arguments).map(shellQuote).joined(separator: " ")
    }

    public var launchInvocation: TerminalLaunchInvocation {
        TerminalLaunchInvocation(plan: self)
    }
}

public struct TerminalLaunchInvocation: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var execName: String

    public init(plan: TerminalCommandPlan) {
        if plan.executable.contains("/") {
            self.executable = plan.executable
            self.arguments = plan.arguments
            self.execName = URL(fileURLWithPath: plan.executable).lastPathComponent
        } else {
            self.executable = "/usr/bin/env"
            self.arguments = [plan.executable] + plan.arguments
            self.execName = plan.executable
        }
    }
}

public struct WorkbenchCommandPlanner: Sendable {
    private let paths: WorkbenchPaths?

    public init(paths: WorkbenchPaths? = nil) {
        self.paths = paths
    }

    public func launchPlan(for entry: ProcessEntry) throws -> TerminalCommandPlan {
        let runId = UUID()
        let transcriptPath = paths?.transcriptURL(entryId: entry.id, runId: runId).path
        return TerminalCommandPlan(
            entryId: entry.id,
            runId: runId,
            executable: entry.executable,
            arguments: entry.arguments,
            workingDirectory: entry.workingDirectory,
            transcriptPath: transcriptPath,
            reason: "launch configured \(entry.name) session"
        )
    }

    public func recoveryPlan(for entry: ProcessEntry, latestRun: ProcessRun?, action: RecoveryAction) throws -> TerminalCommandPlan {
        switch action {
        case .autoResume:
            return try nativeResumePlan(for: entry, latestRun: latestRun, action: action)
        case .respawn:
            var plan = try launchPlan(for: entry)
            if checkpointRecoveryPromptIsNeeded(for: entry) {
                plan.arguments.append(checkpointRecoveryPrompt(for: entry, latestRun: latestRun))
            }
            plan.recoveryAction = action
            plan.reason = checkpointRecoveryPromptIsNeeded(for: entry)
                ? "respawn \(entry.name) with checkpoint recovery prompt"
                : "respawn \(entry.name) from persisted workbench context"
            return plan
        case .manualActionNeeded, .noAction:
            var plan = try launchPlan(for: entry)
            plan.recoveryAction = action
            plan.reason = "prepare \(entry.name) command for manual review"
            return plan
        }
    }

    private func nativeResumePlan(for entry: ProcessEntry, latestRun: ProcessRun?, action: RecoveryAction) throws -> TerminalCommandPlan {
        guard let agentKind = TerminalAgentDetector.detect(entry: entry) else {
            var plan = try launchPlan(for: entry)
            plan.recoveryAction = action
            return plan
        }

        guard let preset = TerminalAgentPresets.preset(for: agentKind) else {
            throw CommandPlanningError.unknownTerminalAgentPreset(agentKind)
        }

        guard let sessionId = latestRun?.terminalSessionId, !sessionId.isEmpty else {
            if let executable = preset.resumeStrategy.fallbackCommandTemplate.first {
                let arguments = preservedResumeArguments(for: entry, preset: preset) + Array(preset.resumeStrategy.fallbackCommandTemplate.dropFirst())
                let runId = UUID()
                return TerminalCommandPlan(
                    entryId: entry.id,
                    runId: runId,
                    executable: executable,
                    arguments: arguments,
                    workingDirectory: entry.workingDirectory,
                    transcriptPath: paths?.transcriptURL(entryId: entry.id, runId: runId).path,
                    recoveryAction: action,
                    reason: "resume \(entry.name) using latest-session fallback"
                )
            }
            throw CommandPlanningError.missingSessionId(entryName: entry.name)
        }

        let rendered = preset.resumeStrategy.commandTemplate.map { token in
            token.replacingOccurrences(of: "{{sessionId}}", with: sessionId)
        }
        let executable = rendered.first ?? entry.executable
        let arguments = preservedResumeArguments(for: entry, preset: preset) + Array(rendered.dropFirst())
        let runId = UUID()
        return TerminalCommandPlan(
            entryId: entry.id,
            runId: runId,
            executable: executable,
            arguments: arguments,
            workingDirectory: entry.workingDirectory,
            transcriptPath: paths?.transcriptURL(entryId: entry.id, runId: runId).path,
            recoveryAction: action,
            reason: "resume \(entry.name) using native session metadata"
        )
    }

    private func preservedResumeArguments(for entry: ProcessEntry, preset: TerminalAgentPreset) -> [String] {
        let tokens = TerminalAgentDetector.canonicalTokens(entry: entry)
        let explicitResumeTokens = Set(
            (preset.resumeStrategy.commandTemplate + preset.resumeStrategy.fallbackCommandTemplate)
                .dropFirst()
                .filter { !$0.contains("{{") }
        )
        return tokens.arguments.filter { !explicitResumeTokens.contains($0) }
    }

    private func checkpointRecoveryPromptIsNeeded(for entry: ProcessEntry) -> Bool {
        guard
            entry.kind == .terminalAgent,
            let agentKind = TerminalAgentDetector.detect(entry: entry),
            let preset = TerminalAgentPresets.preset(for: agentKind)
        else {
            return false
        }
        return preset.resumeStrategy.kind == .checkpointPrompt
    }

    private func checkpointRecoveryPrompt(for entry: ProcessEntry, latestRun: ProcessRun?) -> String {
        var pieces = [
            "Recover this Ouro Workbench terminal-agent session after an app or computer restart.",
            "Working directory: \(entry.workingDirectory).",
            "Inspect current repo state and continue the prior task autonomously.",
        ]
        if let transcriptPath = latestRun?.transcriptPath, !transcriptPath.isEmpty {
            pieces.append("Previous transcript path: \(transcriptPath). Use it as checkpoint context if available.")
        } else {
            pieces.append("No previous transcript path is available; reconstruct context from the workspace and continue carefully.")
        }
        return pieces.joined(separator: " ")
    }
}

private func shellQuote(_ value: String) -> String {
    guard !value.isEmpty else {
        return "''"
    }
    if value.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "'\"\\$`"))) == nil {
        return value
    }
    return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}
