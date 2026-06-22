import Foundation

public enum OuroAgentInstallCommandError: Error, Equatable, LocalizedError, Sendable {
    case emptyAgentName
    case invalidAgentName(String)
    case emptyRemote

    public var errorDescription: String? {
        switch self {
        case .emptyAgentName:
            return "Agent name is required."
        case let .invalidAgentName(agentName):
            return "Agent name cannot be used as a bundle name: \(agentName)"
        case .emptyRemote:
            return "Clone remote is required."
        }
    }
}

/// U15 — the pure validation→(isInvalid, message) mapping behind the clone sheet's
/// optional agent-name field. The field is OPTIONAL (blank defaults to the repo name),
/// so a blank name is valid and carries no message; only a non-blank-but-malformed name
/// is invalid, which both disables the clone action AND surfaces a labeled inline error
/// near the field. The legality rule is the shared `isValidAgentBundleName` — the single
/// source of truth — so the clone field can't disagree with the rest of the app. The
/// wording matches the native "Create your agent" form's `newAgentNameValidationMessage`
/// so the two name fields read identically.
public enum CloneAgentNameValidation {
    /// The result of evaluating a typed clone agent-name field.
    public struct Result: Equatable, Sendable {
        /// Whether the (non-blank) name is malformed. `false` for a blank name — blank is
        /// the valid "default to the repo name" path — and `false` for a well-formed name.
        public let isInvalid: Bool
        /// The seam-free inline error to show near the field, or nil when there's nothing
        /// to say (blank or valid). Never routed through the command preview.
        public let message: String?

        public init(isInvalid: Bool, message: String?) {
            self.isInvalid = isInvalid
            self.message = message
        }
    }

    /// The seam-free inline message for a malformed clone name. Mirrors the native
    /// new-agent form's wording (`ProviderConfigForm.newAgentNameValidationMessage`) so a
    /// bad name reads the same everywhere an agent is named.
    public static let invalidMessage = "That name can't be used. Avoid slashes, colons, and backslashes."

    /// Map a raw field value to `(isInvalid, message)`. Trims first; a blank result is
    /// valid (optional field); otherwise the name must pass `isValidAgentBundleName`.
    public static func evaluate(_ rawName: String) -> Result {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return Result(isInvalid: false, message: nil)
        }
        guard BossWorkbenchMCPRegistrar.isValidAgentBundleName(trimmed) else {
            return Result(isInvalid: true, message: invalidMessage)
        }
        return Result(isInvalid: false, message: nil)
    }
}

public struct OuroAgentInstallPlan: Equatable, Sendable {
    public var sessionName: String
    public var commandLine: String
    public var notes: String
    /// The natively-built argv tokens (first token `ouro`). U35 runs the clone headlessly
    /// from these — the credential/remote reach the runtime via argv, never agent context.
    public var tokens: [String]

    public init(sessionName: String, commandLine: String, notes: String, tokens: [String] = []) {
        self.sessionName = sessionName
        self.commandLine = commandLine
        self.notes = notes
        self.tokens = tokens
    }
}

public struct OuroAgentInstallCommandBuilder: Sendable {
    public init() {}

    public func hatch() -> OuroAgentInstallPlan {
        return OuroAgentInstallPlan(
            sessionName: "Hatch Ouro Agent",
            commandLine: ShellArgumentEscaper.commandLine(["ouro", "hatch"]),
            notes: "Conversational Ouro hatch flow launched from Workbench.",
            tokens: ["ouro", "hatch"]
        )
    }

    public func clone(remote: String, agentName: String?) throws -> OuroAgentInstallPlan {
        let normalizedRemote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRemote.isEmpty else {
            throw OuroAgentInstallCommandError.emptyRemote
        }

        var tokens = ["ouro", "clone", normalizedRemote]
        let normalizedAgentName = try agentName.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : try self.normalizedAgentName(trimmed)
        }
        if let normalizedAgentName {
            tokens += ["--agent", normalizedAgentName]
        }

        return OuroAgentInstallPlan(
            sessionName: normalizedAgentName.map { "Clone \($0)" } ?? "Clone Ouro Agent",
            commandLine: ShellArgumentEscaper.commandLine(tokens),
            notes: "Ouro agent clone flow launched from Workbench.",
            tokens: tokens
        )
    }

    func normalizedAgentName(_ agentName: String) throws -> String {
        let normalizedAgentName = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAgentName.isEmpty else {
            throw OuroAgentInstallCommandError.emptyAgentName
        }
        guard BossWorkbenchMCPRegistrar.isValidAgentBundleName(normalizedAgentName) else {
            throw OuroAgentInstallCommandError.invalidAgentName(normalizedAgentName)
        }
        return normalizedAgentName
    }
}

/// U35 — the pure state model behind the native clone flow's inline progress. The clone
/// sheet drives this and renders progress / success / failure inline (mirroring the
/// cold-start hatch path's headless inline reporting), instead of exposing a literal
/// `ouro clone …` string and spawning a terminal the operator must converse with.
public enum CloneAgentFlowState: Equatable, Sendable {
    /// Nothing in flight — the form is editable and the clone action is armed.
    case idle
    /// A clone is running headlessly; `remoteLabel` is the short, human-readable remote.
    case cloning(remoteLabel: String)
    /// The clone finished; `agentName` is the resolved name when one is known.
    case succeeded(agentName: String?)
    /// The clone failed; `reason` is a seam-free inline line (no argv, no shell jargon).
    case failed(reason: String)

    /// Whether the clone action can fire. True when idle or after a failure (retry); false
    /// while a clone is in flight or after success.
    public var canStart: Bool {
        switch self {
        case .idle, .failed:
            return true
        case .cloning, .succeeded:
            return false
        }
    }

    /// Whether a clone is in flight (drives the spinner and disables the field).
    public var isBusy: Bool {
        if case .cloning = self {
            return true
        }
        return false
    }

    /// Whether the current state is an error (drives the red tint on the inline message).
    public var isError: Bool {
        if case .failed = self {
            return true
        }
        return false
    }

    /// The seam-free inline line for the current state, or nil when there's nothing to say.
    public var inlineMessage: String? {
        switch self {
        case .idle:
            return nil
        case let .cloning(remoteLabel):
            return "Cloning \(remoteLabel)…"
        case let .succeeded(agentName):
            if let agentName, !agentName.isEmpty {
                return "Cloned \(agentName)."
            }
            return "Clone complete."
        case let .failed(reason):
            return reason
        }
    }

    /// Derive a short, human-readable label for a remote — the trailing path component
    /// without the `.ouro` / `.git` suffixes — for the progress line. Falls back to the
    /// trimmed remote, then to a generic phrase when there's nothing usable.
    public static func remoteLabel(forRemote remote: String) -> String {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "the remote"
        }
        // Split on both `/` (URL paths) and `:` (scp-style `git@host:org/repo`) so the
        // last component is the repo name regardless of remote form.
        let lastComponent = trimmed
            .split(whereSeparator: { $0 == "/" || $0 == ":" })
            .last
            .map(String.init) ?? trimmed
        var name = lastComponent
        for suffix in [".git", ".ouro"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? trimmed : cleaned
    }

    /// The seam-free failure line for a clone that threw — names the remote, points at the
    /// fixable cause, and never leaks raw argv or shell jargon.
    public static func failureReason(forRemoteLabel remoteLabel: String) -> String {
        "Couldn't clone \(remoteLabel). Check the Git remote and try again."
    }
}

/// Runs a built `ouro clone …` plan headlessly (no spawned pane) and waits for it to
/// finish — mirroring `ColdStartHatchRunner.runHeadless` so the native clone flow reports
/// inline instead of dumping the operator into a CLI conversation.
///
/// SECURITY: the remote (and any `--agent` name) reach `ouro clone` ONLY here, as argv
/// tokens built natively from the form — never through the agent's context/transcript/MCP.
public enum CloneAgentRunner {
    /// Run the built clone plan headlessly and wait for it to exit, REPORTING the outcome.
    /// The plan's first token is `ouro`, so the remaining tokens are passed as argv to
    /// `/usr/bin/env`.
    ///
    /// F7 — this used to THROW `CloneFailedError` on any non-zero exit and silently
    /// kill-then-throw on a 120s watchdog timeout, so the App mapped EVERY failure (including a
    /// wedge) to "Check the Git remote" — the wrong cause (gap #3). It now returns a
    /// `CloneRunResult` so the classifier can name the real cause: `.launchFailed` (never started),
    /// `.timedOut` (the watchdog fired — a DISTINCT cause from a real non-zero exit, read from
    /// `waitUntilExitReportingTimeout` BEFORE `terminationStatus`, B-1), or `.exited(code:)`.
    /// `executableURL` is injectable ONLY so a test can point at a non-existent binary to exercise
    /// the `.launchFailed` path (with `/usr/bin/env` hardcoded, `run()` never throws via argv);
    /// production always uses the default `/usr/bin/env`. Mirrors `ColdStartHatchRunner.runHeadless`.
    @Sendable
    public static func runHeadless(
        plan: OuroAgentInstallPlan,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/env")
    ) async -> CloneRunResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = plan.tokens
        process.environment = TerminalEnvironment().valuesWithResolvedPath()

        let devNull = FileHandle.nullDevice
        process.standardInput = devNull
        process.standardOutput = devNull
        process.standardError = devNull

        do {
            try process.run()
        } catch {
            // The process couldn't be launched at all — nothing was cloned.
            return .launchFailed
        }
        // Bound the wait — a clone can legitimately take a while (fetching a repo), but must still
        // not hang forever on a wedged `ouro`/`git` child. Read the watchdog's verdict BEFORE
        // `terminationStatus`: a kill and a real git failure both exit non-zero, so the timeout
        // signal is the ONLY way to tell a 120s wedge apart from a remote failure (gap #3 / B-1).
        let timedOut = ProcessWatchdog.waitUntilExitReportingTimeout(process, timeoutSeconds: 120)
        if timedOut {
            return .timedOut
        }
        return .exited(code: process.terminationStatus)
    }
}
