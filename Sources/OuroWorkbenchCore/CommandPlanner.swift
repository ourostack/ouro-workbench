import Foundation

public enum CommandPlanningError: Error, Equatable, Sendable {
    case unknownTerminalAgentPreset(TerminalAgentKind)
    case missingSessionId(entryName: String)
    case emptyExecutable(entryName: String)
}

/// What a `TerminalCommandPlan` does, as a typed signal (U40). The planner's raw
/// `reason` is precise but technical ("respawn X from persisted workbench
/// context"); the post-launch session-status line and the boss prompt need a plain
/// operator sentence instead. Keying that sentence off this enum — not the prose —
/// is the same shape `RecoveryReasonPhrasebook` uses for `RecoveryAction`, so the
/// status reads plainly while the raw reason stays available for logs / disclosure.
public enum TerminalCommandPlanKind: String, Codable, Sendable, CaseIterable {
    /// A fresh start of a configured session.
    case launch
    /// Reconnect to a session that's still alive under `screen`.
    case reattach
    /// Auto-resume a session's last conversation (native or fallback resume).
    case resume
    /// Reopen a session from its saved checkpoint context.
    case respawn
    /// A command staged for the operator to inspect before running.
    case manualReview
}

/// How a respawn's checkpoint recovery prompt reaches the agent (#F12a gap 5).
///
/// The planner used to append the prompt as the last positional argv token. That
/// works for a generic argv-reading TUI, but Copilot's launch
/// (`gh copilot -- --yolo "<prompt>"`) ignores anything after `--`, so the TUI
/// opened with no recovery context. This typed signal lets the session controller
/// route Copilot's prompt to be typed AFTER the TUI is interactive instead.
public enum CheckpointPromptDelivery: Equatable, Sendable {
    /// The prompt is already in `arguments` (appended) — a generic argv-reading TUI
    /// that consumes an argv prompt. The controller does nothing extra.
    case positional
    /// The prompt is NOT in `arguments`; the controller must type it (via
    /// `sendInput`) once the session reaches its interactive (first-output) state.
    /// Copilot's TUI ignores an argv prompt after `--`, so this is the only way it
    /// receives recovery context.
    case sendAfterLaunch(String)
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
    /// The typed meaning of this plan (U40). Drives the plain operator sentence
    /// shown post-launch; the raw `reason` stays untouched for logs / disclosure.
    public var kind: TerminalCommandPlanKind
    /// How a respawn's checkpoint recovery prompt is delivered (#F12a gap 5).
    /// `.positional` (the default) for everything but a Copilot respawn, which uses
    /// `.sendAfterLaunch` so the prompt is typed after the TUI is interactive.
    public var checkpointPromptDelivery: CheckpointPromptDelivery

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
        reason: String,
        kind: TerminalCommandPlanKind = .launch,
        checkpointPromptDelivery: CheckpointPromptDelivery = .positional
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
        self.kind = kind
        self.checkpointPromptDelivery = checkpointPromptDelivery
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

    /// Parse `screen -ls` output into the set of *live* Workbench session names
    /// (Attached or Detached). Dead sockets are excluded: a dead session must be
    /// respawned (with its checkpoint context), not falsely "reattached" to
    /// nothing. Each session line looks like `12345.ouro-wb-<id>\t(Detached)`.
    public static func liveSessionNames(fromListOutput output: String) -> Set<String> {
        var names: Set<String> = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let firstField = line.split(whereSeparator: \.isWhitespace).first.map(String.init),
                  let dot = firstField.firstIndex(of: ".") else {
                continue
            }
            let name = String(firstField[firstField.index(after: dot)...])
            guard name.hasPrefix("ouro-wb-") else {
                continue
            }
            let lowered = line.lowercased()
            // Only count sessions screen can actually reattach to.
            guard lowered.contains("(detached)") || lowered.contains("(attached)") else {
                continue
            }
            names.insert(name)
        }
        return names
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

/// Decides how a respawn's checkpoint prompt is delivered, keyed off the detected
/// agent kind (#F12a gap 5). Pure — no I/O — so the App's session controller and the
/// planner agree without either reaching for agent-specific logic inline.
public struct CheckpointPromptDeliveryResolver: Sendable {
    public init() {}

    /// `.sendAfterLaunch(prompt)` for Copilot (its TUI ignores an argv prompt after
    /// `--`, so it must be typed once interactive); `.positional` for a generic
    /// argv-reading TUI (detection nil / `.custom`) that consumes an argv prompt;
    /// `nil` for the native-resume agents (Claude / Codex) — they never respawn via
    /// the checkpoint prompt, so no checkpoint delivery applies.
    public func delivery(for kind: TerminalAgentKind?, prompt: String) -> CheckpointPromptDelivery? {
        switch kind {
        case .githubCopilotCLI:
            return .sendAfterLaunch(prompt)
        case nil, .custom:
            return .positional
        case .claudeCode, .openAICodex:
            return nil
        }
    }
}

public struct WorkbenchCommandPlanner: Sendable {
    private let paths: WorkbenchPaths?

    public init(paths: WorkbenchPaths? = nil) {
        self.paths = paths
    }

    public func launchPlan(for entry: ProcessEntry) throws -> TerminalCommandPlan {
        // A blank executable would synthesize `/usr/bin/env ''`, which exits
        // with an opaque "No such file or directory". Fail with a clear,
        // actionable error instead. (UI session creation requires a command,
        // but a hand-edited .workbench.json or malformed entry can reach here.)
        guard !entry.executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandPlanningError.emptyExecutable(entryName: entry.name)
        }
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
        case .reattach:
            // The screen session is still alive; `screen -D -RR` reconnects to it
            // and ignores the command, so a plain launch plan reattaches without
            // a checkpoint prompt or native-resume command.
            var plan = try launchPlan(for: entry)
            plan.recoveryAction = action
            plan.reason = "reconnect to running \(entry.name)"
            plan.kind = .reattach
            return plan
        case .autoResume:
            return try nativeResumePlan(for: entry, latestRun: latestRun, action: action)
        case .respawn:
            var plan = try launchPlan(for: entry)
            let needsPrompt = checkpointRecoveryPromptIsNeeded(for: entry)
            if needsPrompt {
                let prompt = checkpointRecoveryPrompt(for: entry, latestRun: latestRun)
                // F12a gap 5 — choose the delivery by detected agent kind. Copilot's
                // TUI ignores an argv prompt after `--`, so its prompt is carried in
                // `checkpointPromptDelivery` (.sendAfterLaunch) to be typed once the
                // TUI is interactive — NOT appended to arguments. A generic
                // argv-reading TUI keeps the positional path (appended). The resolver
                // returns nil only for native-resume agents, which never reach here.
                let detected = TerminalAgentDetector.detect(entry: entry)
                if case .sendAfterLaunch = CheckpointPromptDeliveryResolver().delivery(for: detected, prompt: prompt) {
                    plan.checkpointPromptDelivery = .sendAfterLaunch(prompt)
                } else {
                    plan.arguments.append(prompt)
                    plan.checkpointPromptDelivery = .positional
                }
            }
            plan.recoveryAction = action
            plan.reason = needsPrompt
                ? "respawn \(entry.name) with checkpoint recovery prompt"
                : "respawn \(entry.name) from persisted workbench context"
            plan.kind = .respawn
            return plan
        case .manualActionNeeded, .noAction:
            var plan = try launchPlan(for: entry)
            plan.recoveryAction = action
            plan.reason = "prepare \(entry.name) command for manual review"
            plan.kind = .manualReview
            return plan
        }
    }

    private func nativeResumePlan(for entry: ProcessEntry, latestRun: ProcessRun?, action: RecoveryAction) throws -> TerminalCommandPlan {
        guard let agentKind = TerminalAgentDetector.detect(entry: entry) else {
            var plan = try launchPlan(for: entry)
            plan.recoveryAction = action
            plan.kind = .resume
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
                    reason: "resume \(entry.name) using latest-session fallback",
                    kind: .resume
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
            reason: "resume \(entry.name) using native session metadata",
            kind: .resume
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
