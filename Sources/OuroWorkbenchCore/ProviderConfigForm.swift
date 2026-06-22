import Foundation

/// A provider supported by the native provider-config form — exactly the five `ouro`
/// `isAgentProvider` providers (`azure | anthropic | minimax | openai-codex | github-copilot`).
///
/// Each case declares the human-facing credential fields it needs and how those map to the
/// cold-start `ouro hatch` argv credential sink. The mapping is the SOLE place the form knows
/// about `ouro`'s credential flags — and even here the values are only assembled into command
/// tokens; they never route through the agent's context.
public enum WorkbenchProvider: String, CaseIterable, Identifiable, Equatable, Sendable {
    case azure
    case anthropic
    case minimax
    case openaiCodex
    case githubCopilot

    public var id: String { rawValue }

    /// The raw `--provider` value passed to `ouro hatch` (an audit/command surface, not human copy).
    public var providerFlagValue: String {
        switch self {
        case .azure: return "azure"
        case .anthropic: return "anthropic"
        case .minimax: return "minimax"
        case .openaiCodex: return "openai-codex"
        case .githubCopilot: return "github-copilot"
        }
    }

    /// Seam-free human-facing provider name for the picker. No `ouro`/CLI vocabulary.
    public var displayName: String {
        switch self {
        case .azure: return "Azure OpenAI"
        case .anthropic: return "Anthropic"
        case .minimax: return "MiniMax"
        case .openaiCodex: return "OpenAI"
        case .githubCopilot: return "GitHub Copilot"
        }
    }

    /// The ordered credential fields the form collects for this provider. The order is the
    /// argv order the cold-start command builds them in.
    public var credentialFields: [ProviderCredentialField] {
        switch self {
        case .anthropic:
            return [ProviderCredentialField(key: "setupToken", label: "Anthropic setup token", isSecret: true)]
        case .openaiCodex:
            return [ProviderCredentialField(key: "oauthToken", label: "OpenAI sign-in token", isSecret: true)]
        case .minimax:
            return [ProviderCredentialField(key: "apiKey", label: "MiniMax API key", isSecret: true)]
        case .azure:
            return [
                ProviderCredentialField(key: "apiKey", label: "Azure API key", isSecret: true),
                ProviderCredentialField(key: "endpoint", label: "Azure endpoint", isSecret: false),
                ProviderCredentialField(key: "deployment", label: "Azure deployment", isSecret: false),
            ]
        case .githubCopilot:
            return [ProviderCredentialField(key: "githubToken", label: "GitHub token", isSecret: true)]
        }
    }

    /// Whether a brand-new agent can be created for this provider headlessly through the
    /// cold-start `ouro hatch` argv credential sink.
    ///
    /// `ouro hatch` accepts only `--setup-token` / `--oauth-token` / `--api-key` / `--endpoint`
    /// / `--deployment`. GitHub Copilot's credentials (`githubToken` + `baseUrl`) have NO hatch
    /// argv flag, so cold-start via argv is genuinely unavailable for it today — the documented
    /// narrow gap. The form reports that honestly rather than fabricating a command.
    public var supportsColdStartHatch: Bool {
        self != .githubCopilot
    }

    /// Build the cold-start hatch credential from this provider's collected field values.
    ///
    /// Returns `nil` for a provider with no argv cold-start sink (GitHub Copilot). All values
    /// are pre-trimmed by the caller. The credential is carried only to assemble command tokens.
    func hatchCredential(from values: [String: String]) -> BootstrapHatchCredential? {
        switch self {
        case .anthropic:
            return .setupToken(values["setupToken"] ?? "")
        case .openaiCodex:
            return .oauthToken(values["oauthToken"] ?? "")
        case .minimax:
            return .apiKey(values["apiKey"] ?? "")
        case .azure:
            // Azure carries apiKey AND endpoint/deployment. The `BootstrapHatchCredential`
            // endpoint case models endpoint+deployment; the apiKey is appended separately.
            return .endpoint(endpoint: values["endpoint"] ?? "", deployment: values["deployment"] ?? "")
        case .githubCopilot:
            return nil
        }
    }
}

/// One human-facing credential field the provider-config form collects.
public struct ProviderCredentialField: Equatable, Identifiable, Sendable {
    /// The internal key (matches the `values` dictionary the form submits with). Not human copy.
    public let key: String
    /// The seam-free human-facing label shown in the form.
    public let label: String
    /// Whether the field holds a secret (rendered with a secure entry field).
    public let isSecret: Bool

    public var id: String { key }

    public init(key: String, label: String, isSecret: Bool) {
        self.key = key
        self.label = label
        self.isSecret = isSecret
    }
}

/// The result of submitting the native provider-config form.
///
/// Mirrors `ReleaseUpdateMenuOutcome`: a pure value the SwiftUI view acts on, so all of the
/// branching / validation / command-construction is unit-testable without AppKit. The secret
/// reaches `ouro hatch` ONLY through the `coldStartHatch` plan's argv tokens — never through
/// the agent's context/MCP.
public enum ProviderConfigFormOutcome: Equatable, Sendable {
    /// Cold-start: a brand-new agent. The built (but not-yet-executed) headless `ouro hatch`
    /// plan with the matching credential flags — the app runs it headlessly.
    case coldStartHatch(BootstrapAgentProvisionPlan)
    /// The form input is incomplete/invalid; `message` is seam-free human copy for the form.
    case invalid(String)
    /// This provider has no cold-start argv sink today (GitHub Copilot). A clearly-flagged,
    /// honest outcome — NOT a fabricated command and NOT a CLI pane. `message` is seam-free.
    case unsupportedColdStartSink(String)
}

/// The pure model behind the native provider-config form (the ONE human gate).
///
/// Holds the explicit resolved agent + human names (never `ouro`'s default-agent resolution)
/// and turns a chosen provider + entered credential fields into a `ProviderConfigFormOutcome`.
/// Pure + free of I/O so the SwiftUI view is wiring + a thin assert and all the
/// validation/branching/command-construction is tested here.
public struct ProviderConfigForm: Sendable {
    public let agentName: String
    public let humanName: String

    public init(agentName: String, humanName: String) {
        self.agentName = agentName
        self.humanName = humanName
    }

    /// The form's seam-free title. Reads as one product — "your agent", no `ouro`/CLI seam.
    public var title: String {
        "Connect your agent's provider"
    }

    /// The form's seam-free subtitle/explainer.
    public var subtitle: String {
        "Choose a provider and enter your credentials so your agent can start working. This is the only step that needs you."
    }

    // NOTE (F6): the former `existingAgentRefreshUnavailableMessage` (the "not available yet" gap-a
    // copy) is gone — an existing agent's Connect now drives a real credential ROTATION via the
    // native unlock-chain terminal (`WorkbenchViewModel.beginCredentialRotation`), so there is no
    // longer a dead-end to surface. There is still no headless non-interactive `ouro` credential-set
    // sink (gap a stands), which is exactly why rotation re-collects the credential in a real TTY
    // rather than persisting silently — see `VaultOnboardingCommand.rotateCredentialCommandLine`.

    /// Validate a brand-new agent's name for cold-start creation (the empty-machine /
    /// "create an agent" path). Returns a seam-free message if invalid, else nil.
    /// `existingNames` are the already-installed agents — a new agent must not collide
    /// with one (that would be the existing-agent refresh path, not a fresh hatch).
    public static func newAgentNameValidationMessage(_ name: String, existingNames: [String]) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Please give your agent a name."
        }
        guard BossWorkbenchMCPRegistrar.isValidAgentBundleName(trimmed) else {
            return "That name can't be used. Avoid slashes, colons, and backslashes."
        }
        if existingNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "An agent named \(trimmed) already exists. Pick a different name."
        }
        return nil
    }

    /// Validate + build the cold-start outcome for the chosen provider and entered field values.
    ///
    /// COLD-START path only (a brand-new agent → headless hatch). Refreshing an EXISTING agent's
    /// provider credentials headlessly has no `ouro` sink today (the documented narrow gap); that
    /// is surfaced via `unsupportedColdStartSink` for providers with no argv flag, and is flagged
    /// at the existing-agent call site — never by reopening a CLI pane.
    public func submit(provider: WorkbenchProvider, values: [String: String]) -> ProviderConfigFormOutcome {
        // Trim every collected value up front; the cold-start command uses the trimmed values.
        var trimmed: [String: String] = [:]
        for field in provider.credentialFields {
            trimmed[field.key] = (values[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Every required field must be present (seam-free message names the human labels).
        let missingLabels = Self.missingCredentialLabels(fields: provider.credentialFields, trimmed: trimmed)
        guard missingLabels.isEmpty else {
            return .invalid("Please fill in: \(missingLabels.joined(separator: ", ")).")
        }

        // The agent + human names must be present (the explicit-resolved-name guard).
        guard !agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalid("Workbench couldn't identify your agent. Please reopen Workbench and try again.")
        }
        guard !humanName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalid("Please tell Workbench your name so it can set up your agent.")
        }

        // GitHub Copilot (and any future provider without an argv sink) cannot cold-start
        // headlessly today. Report honestly — no fabricated command, no CLI pane.
        guard provider.supportsColdStartHatch, let credential = provider.hatchCredential(from: trimmed) else {
            return .unsupportedColdStartSink(
                "\(provider.displayName) can't be connected automatically yet. Workbench will add this soon — for now, choose another provider to get your agent online."
            )
        }

        // Build the headless cold-start command. Azure additionally carries its apiKey, which the
        // endpoint-style credential does not model, so weave it in right after the provider value.
        do {
            let plan = try BootstrapAgentProvisionCommand.hatch(
                agentName: agentName,
                humanName: humanName,
                provider: provider.providerFlagValue,
                credential: credential
            )
            guard provider == .azure, let apiKey = trimmed["apiKey"], !apiKey.isEmpty else {
                return .coldStartHatch(plan)
            }

            return .coldStartHatch(withAzureApiKey(apiKey, into: plan, provider: provider))
        } catch {
            return .invalid("Workbench couldn't set up your agent. Please reopen Workbench and try again.")
        }
    }

    static func missingCredentialLabels(fields: [ProviderCredentialField], trimmed: [String: String]) -> [String] {
        fields
            .filter { (trimmed[$0.key] ?? "").isEmpty }
            .map(\.label)
    }

    /// Weave Azure's `--api-key` flag in right after the `--provider azure` value so the argv
    /// reads provider → api-key → endpoint → deployment. The provider value is always present in
    /// a freshly-built hatch plan, so the index always resolves.
    func withAzureApiKey(
        _ apiKey: String,
        into plan: BootstrapAgentProvisionPlan,
        provider: WorkbenchProvider
    ) -> BootstrapAgentProvisionPlan {
        var tokens = plan.tokens
        let index = (tokens.firstIndex(of: provider.providerFlagValue) ?? tokens.count - 1) + 1
        tokens.insert(contentsOf: ["--api-key", apiKey], at: index)
        return BootstrapAgentProvisionPlan(tokens: tokens)
    }

    /// F1 — classify a cold-start creation from the `ouro hatch` exit plus the post-hatch
    /// `ouro check` verdict. PURE: no I/O, fully unit-tested, so the App wiring stays a thin
    /// fold from `runHeadless` + a probe into a side-effect branch.
    ///
    /// - `hatchExitCode`: the hatch exit, or `nil` when the process never launched (`.launchFailed`).
    /// - `checkVerdict`: the `ProviderCheckClassifier` verdict for the configured lane, or `nil`
    ///   when the probe timed out / couldn't run (a flaky-daemon hang hitting the short watchdog).
    ///
    /// LOAD-BEARING: a clean hatch is NEVER reported `.ready` unless the probe positively says
    /// `.working`. Anything short of that is `.needsVaultSetup` (the agent exists but isn't
    /// connected) or `.failed(.couldNotConfirm)` (we genuinely don't know) — never a false green.
    public static func classifyColdStart(
        hatchExitCode: Int32?,
        checkVerdict: ProviderConnectionVerdict?
    ) -> ColdStartOutcome {
        // The hatch never launched: nothing was created, regardless of any later probe.
        guard let exitCode = hatchExitCode else {
            return .failed(reason: .hatchLaunchError)
        }
        // The hatch ran but failed: agent.json / credential state is untrustworthy.
        guard exitCode == 0 else {
            return .failed(reason: .hatchNonZeroExit)
        }
        // A clean hatch — the truth is now entirely the probe's:
        switch checkVerdict {
        case .working:
            return .ready
        case .vaultLocked, .unauthorized:
            // The agent exists but its provider isn't connected yet — route to finish setup.
            return .needsVaultSetup
        case .unreachable, .indeterminate, nil:
            // Can't positively confirm (network down, ambiguous output, or probe timed out).
            return .failed(reason: .couldNotConfirm)
        }
    }
}

/// Runs a built cold-start `ouro hatch` plan headlessly (no spawned pane).
///
/// Mirrors `AgentRepairRunner.headlessRepair`: spawns `/usr/bin/env ouro …` with
/// `TerminalEnvironment().valuesWithResolvedPath()` so `ouro` resolves from a Finder-launched
/// `.app`'s minimal PATH, routes stdio to /dev/null, and WAITS for the finite hatch to finish.
///
/// SECRET PATH: the credential reaches `ouro hatch` ONLY here, as argv tokens built natively
/// from the form — it never passes through the agent's context/transcript/MCP. (Argv is briefly
/// visible in `ps` to the same local user; flagged as the interim cold-start posture, Open Q a.)
public enum ColdStartHatchRunner {
    /// Run the built plan headlessly and wait for it to exit. The plan's first token is `ouro`,
    /// so the remaining tokens are passed as argv to `/usr/bin/env`.
    ///
    /// F1: this used to DELIBERATELY ignore the exit status — which is exactly how a dead,
    /// credential-less `ouro hatch` (agent.json written, but the headless vault step threw)
    /// reported success and dumped the user at a silent dead end. It now REPORTS the outcome
    /// (`.launchFailed` if the process couldn't even start, `.exited(code:)` otherwise) so the
    /// caller can probe + classify honestly. Mirrors `CloneAgentRunner.runHeadless`'s exit guard.
    /// `executableURL` is injectable ONLY so a test can point at a non-existent binary to exercise
    /// the `.launchFailed` path deterministically (with `/usr/bin/env` hardcoded, `run()` never
    /// throws via argv — `env` always launches and reports an exit code). Production always uses
    /// the default `/usr/bin/env`.
    @Sendable
    public static func runHeadless(
        plan: BootstrapAgentProvisionPlan,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/env")
    ) async -> ColdStartRunResult {
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
            // The process couldn't be launched at all (e.g. `env` can't resolve the command).
            // That is distinct from a non-zero exit: the hatch never ran, so nothing was created.
            return .launchFailed
        }
        // Bound the wait — a cold-start hatch can legitimately take longer (provisioning),
        // but must still not hang forever on a wedged `ouro`/`node` child.
        ProcessWatchdog.waitUntilExit(process, timeoutSeconds: 60)
        return .exited(code: process.terminationStatus)
    }
}

/// The outcome of running a headless cold-start `ouro hatch` plan.
///
/// `.launchFailed` means the process could not be started at all (nothing was created);
/// `.exited(code:)` carries the real `ouro hatch` exit status. The App folds `.launchFailed` to
/// `nil` and `.exited` to its code before handing to `ProviderConfigForm.classifyColdStart`.
public enum ColdStartRunResult: Equatable, Sendable {
    case exited(code: Int32)
    case launchFailed

    /// The exit code for an `.exited` run, or `nil` for `.launchFailed` (never launched). The
    /// classifier treats `nil` hatch exit as a launch error.
    public var exitCode: Int32? {
        switch self {
        case let .exited(code):
            return code
        case .launchFailed:
            return nil
        }
    }
}

// MARK: - F1 cold-start outcome classification

/// Why a cold-start creation could not be reported as ready. Carries a stable `rawValue` for the
/// audit log (NOT human copy — `humanFacingLine` is the human surface).
public enum ColdStartFailureReason: String, Equatable, Sendable {
    /// The `ouro hatch` process could not be launched at all.
    case hatchLaunchError
    /// `ouro hatch` ran but exited non-zero.
    case hatchNonZeroExit
    /// `ouro hatch` exited 0 but the post-hatch probe could not confirm the agent is usable
    /// (network-unreachable, indeterminate output, or the probe itself timed out).
    case couldNotConfirm
}

/// The honest classification of a cold-start creation attempt.
///
/// `.ready` — created and verified working. `.needsVaultSetup` — created, but its provider isn't
/// connected yet (the agent exists; the human still needs to finish credential setup).
/// `.failed` — creation could not be completed/confirmed. This is the value that replaces the
/// old unconditional `succeeded: true`: the form now reports the truth.
public enum ColdStartOutcome: Equatable, Sendable {
    case ready
    case needsVaultSetup
    case failed(reason: ColdStartFailureReason)

    /// A stable, non-human audit token for this outcome (for the action log's `result:` line —
    /// NOT a human surface). `humanFacingLine` is the human copy.
    public var auditReason: String {
        switch self {
        case .ready:
            return "ready"
        case .needsVaultSetup:
            return "needsVaultSetup"
        case let .failed(reason):
            return reason.rawValue
        }
    }

    /// Seam-free human copy for the cold-start result. Names the agent; never leaks `ouro`/`hatch`/
    /// `vault`/argv flags. The same surface drives the success line and the honest-failure line.
    public func humanFacingLine(agentName: String) -> String {
        switch self {
        case .ready:
            return "\(agentName) is connected and ready."
        case .needsVaultSetup:
            return "\(agentName) was created, but its provider isn't connected yet — "
                + "Workbench will help you finish setup."
        case .failed:
            return "Workbench couldn't finish creating \(agentName). "
                + "Please check your details and try again."
        }
    }
}
