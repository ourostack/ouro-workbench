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
    public var persistentSessionName: String?
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
        persistentSessionName: String? = nil,
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
        self.persistentSessionName = persistentSessionName
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
        let direct = Self.directInvocation(for: plan)
        guard let sessionName = plan.persistentSessionName else {
            self = direct
            return
        }
        self.executable = PersistentTerminalSession.executable
        self.arguments = PersistentTerminalSession.attachOrCreateArguments(
            sessionName: sessionName,
            command: [direct.executable] + direct.arguments
        )
        self.execName = PersistentTerminalSession.execName
    }

    private init(executable: String, arguments: [String], execName: String) {
        self.executable = executable
        self.arguments = arguments
        self.execName = execName
    }

    private static func directInvocation(for plan: TerminalCommandPlan) -> TerminalLaunchInvocation {
        if plan.executable.contains("/") {
            return TerminalLaunchInvocation(
                executable: plan.executable,
                arguments: plan.arguments,
                execName: URL(fileURLWithPath: plan.executable).lastPathComponent
            )
        } else {
            return TerminalLaunchInvocation(
                executable: "/usr/bin/env",
                arguments: [plan.executable] + plan.arguments,
                execName: plan.executable
            )
        }
    }
}

public enum PersistentTerminalSession: Sendable {
    public static let systemFallbackExecutable = "/usr/bin/screen"
    public static let bundledExecutableRelativePath = "Contents/MacOS/Tools/screen"
    public static var executable: String {
        executablePath()
    }
    public static let execName = "screen"

    public static func executablePath(
        bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> String {
        let bundledExecutable = bundleURL.appendingPathComponent(bundledExecutableRelativePath).path
        guard fileManager.isExecutableFile(atPath: bundledExecutable) else {
            return systemFallbackExecutable
        }
        return bundledExecutable
    }

    public static func sessionName(for entryId: UUID) -> String {
        "ouro-wb-\(entryId.uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
    }

    public static func attachOrCreateArguments(sessionName: String, command: [String]) -> [String] {
        [
            "-U",
            "-T", "xterm-256color",
            "-h", "0",
            "-e", "^]]",
            "-D",
            "-RR",
            "-S", sessionName,
            "--",
        ] + command
    }

    public static func listArguments() -> [String] {
        ["-ls"]
    }

    public static func terminateArguments(sessionName: String) -> [String] {
        ["-S", sessionName, "-X", "quit"]
    }

    public static func listOutput(_ output: String, contains sessionName: String) -> Bool {
        output
            .split(whereSeparator: \.isNewline)
            .contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let firstField = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) else {
                    return false
                }
                if firstField == sessionName {
                    return true
                }
                guard let separator = firstField.firstIndex(of: ".") else {
                    return false
                }
                return String(firstField[firstField.index(after: separator)...]) == sessionName
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
            persistentSessionName: PersistentTerminalSession.sessionName(for: entry.id),
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
                    persistentSessionName: PersistentTerminalSession.sessionName(for: entry.id),
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
            persistentSessionName: PersistentTerminalSession.sessionName(for: entry.id),
            reason: "resume \(entry.name) using native session metadata"
        )
    }

    private func preservedResumeArguments(for entry: ProcessEntry, preset: TerminalAgentPreset) -> [String] {
        let tokens = TerminalAgentDetector.canonicalTokens(entry: entry)
        let strategyArguments = [
            Array(preset.resumeStrategy.commandTemplate.dropFirst()),
            Array(preset.resumeStrategy.fallbackCommandTemplate.dropFirst()),
        ].filter { !$0.isEmpty }

        var preserved: [String] = []
        var index = 0
        while index < tokens.arguments.count {
            if let matchedPattern = strategyArguments.first(where: { pattern in
                Self.argumentPattern(pattern, matches: tokens.arguments, at: index)
            }) {
                index += matchedPattern.count
            } else {
                preserved.append(tokens.arguments[index])
                index += 1
            }
        }
        return preserved
    }

    private static func argumentPattern(_ pattern: [String], matches arguments: [String], at index: Int) -> Bool {
        guard !pattern.isEmpty, index + pattern.count <= arguments.count else {
            return false
        }
        for (offset, patternToken) in pattern.enumerated() {
            if patternToken.contains("{{") {
                continue
            }
            guard arguments[index + offset] == patternToken else {
                return false
            }
        }
        return true
    }

    private func checkpointRecoveryPromptIsNeeded(for entry: ProcessEntry) -> Bool {
        guard entry.kind == .terminalAgent else {
            return false
        }
        guard let agentKind = TerminalAgentDetector.detect(entry: entry) else {
            return true
        }
        guard let preset = TerminalAgentPresets.preset(for: agentKind) else {
            return true
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
