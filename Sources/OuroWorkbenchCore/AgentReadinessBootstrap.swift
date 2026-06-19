import Foundation

// MARK: - Steps

/// The ordered Layer-A cold-start bootstrap steps S0→S5.
///
/// This is the *native* cold-start spine that guarantees a healthy Ouro agent exists
/// before Layer B (agent-drives-UI) takes the wheel. Every step is app-executed; the
/// ONLY human gate is `providerConfig` (S2). The steps run in declaration order.
public enum BootstrapStep: String, CaseIterable, Codable, Equatable, Sendable {
    /// S0 — ensure the local daemon is up (detect-reuse-else-start, via Slice 0's manager).
    case ensureDaemon
    /// S1 — ensure a usable agent bundle exists (headless hatch OR clone if absent).
    case ensureAgentExists
    /// S2 — provider configuration: the ONE human gate. Parks here if creds are absent/declined.
    case providerConfig
    /// S3 — vault / provider sync.
    case vaultSync
    /// S4 — verify the configured credentials actually work.
    case verifyCredentials
    /// S5 — register the Workbench MCP for the boss so the agent can drive the UI.
    case registerWorkbenchMCP

    /// Audit/debug label. This is an audit surface — raw `ouro` verbs are allowed here only,
    /// never in the product's human-facing voice.
    public var auditLabel: String {
        switch self {
        case .ensureDaemon:
            return "S0 ensure-daemon (`ouro up`)"
        case .ensureAgentExists:
            return "S1 ensure-agent-exists (`ouro hatch` / `ouro clone`)"
        case .providerConfig:
            return "S2 provider-config (human gate)"
        case .vaultSync:
            return "S3 vault/provider sync"
        case .verifyCredentials:
            return "S4 verify-creds (`ouro auth verify`)"
        case .registerWorkbenchMCP:
            return "S5 register-Workbench-MCP"
        }
    }
}

// MARK: - Recovery truth

/// The post-effect verify truth of a single step. INJECTED by each step's effect; the
/// machine NEVER infers this from an exit code or a thrown error — only from a post-effect
/// verify probe. A step that "ran" without a passing verify is NOT a success.
public enum StepHealth: String, Codable, Equatable, Sendable {
    /// The post-effect verify probe confirms the step's target is healthy.
    case healthy
    /// The effect ran but the post-effect verify still reads degraded (no false "done").
    case stillDegraded
    /// The target cannot be brought up automatically — honest manual-recovery required.
    case needsManual
}

/// Recovery-truth classification for a step, derived ONLY from the post-effect verify.
public enum BootstrapRecoveryTruth: String, Codable, Equatable, Sendable {
    /// Post-effect verify passed — the step is genuinely healthy.
    case verified
    /// Post-effect verify still degraded; the machine halts rather than pretend success.
    case stillDegraded
    /// Could not be brought up automatically — honest manual recovery.
    case needsManual

    /// Classify from a post-effect verify health — never from an exit code.
    public static func classify(_ health: StepHealth) -> BootstrapRecoveryTruth {
        switch health {
        case .healthy:
            return .verified
        case .stillDegraded:
            return .stillDegraded
        case .needsManual:
            return .needsManual
        }
    }

    /// Only `verified` allows the machine to advance to the next step.
    public var didVerify: Bool { self == .verified }
}

// MARK: - Provider credential status (the S2 gate signal)

/// The S2 provider-config gate's result — the only step whose effect is a human touchpoint.
///
/// `absent` / `declined` both PARK the machine (a stable, terminal-ish state); only
/// `credentialsPresent` advances. The gate must be checked exactly once per run — never
/// busy-looped — because its only exit is the human supplying credentials.
public enum ProviderCredentialStatus: String, Codable, Equatable, Sendable {
    /// Usable credentials are present → advance past S2.
    case credentialsPresent
    /// No credentials yet → park (await the human).
    case absent
    /// The human explicitly declined the provider gate → park (await the human).
    case declined

    var advances: Bool { self == .credentialsPresent }
}

// MARK: - Agent context (explicit resolved name)

/// The explicitly-resolved agent identity every step targets.
///
/// HARD RULE: every step that targets an agent carries this EXPLICIT resolved name — the
/// machine never relies on `ouro`'s default-agent resolution (multiple agents can exist on
/// one machine, so an implicit `--agent` could target the wrong one).
public struct BootstrapAgentContext: Equatable, Sendable {
    public var agentName: String
    public var humanName: String
    public var provider: String

    public init(agentName: String, humanName: String, provider: String) {
        self.agentName = agentName
        self.humanName = humanName
        self.provider = provider
    }

    /// The agent name is valid only when it's a usable bundle name (no path separators /
    /// surrounding whitespace / empty) — the wrong-agent guard.
    public var hasValidAgentName: Bool {
        BossWorkbenchMCPRegistrar.isValidAgentBundleName(agentName)
    }
}

// MARK: - Step outcome + result

/// A single executed step's recovery-truth record.
public struct BootstrapStepOutcome: Equatable, Sendable {
    public let step: BootstrapStep
    public let recovery: BootstrapRecoveryTruth

    public init(step: BootstrapStep, recovery: BootstrapRecoveryTruth) {
        self.step = step
        self.recovery = recovery
    }

    /// Audit/debug detail (raw `ouro` verbs allowed here only).
    public var auditDetail: String {
        switch recovery {
        case .verified:
            return "\(step.auditLabel): post-effect verify passed."
        case .stillDegraded:
            return "\(step.auditLabel): post-effect verify still degraded; halted (no false 'done')."
        case .needsManual:
            return "\(step.auditLabel): could not complete automatically; manual recovery required."
        }
    }
}

/// The terminal-ish phase the machine settled into for a single `run()`.
public enum BootstrapPhase: Equatable, Sendable {
    /// The agent name failed the explicit-resolved-name guard; no step ran.
    case failedInvalidAgent
    /// A step's post-effect verify did not pass; the machine halted at that step.
    case failedStep(BootstrapStep)
    /// S2's human gate has no usable credentials (absent/declined) — PARKED, awaiting the
    /// human. A stable, terminal-ish state whose only exit is the human supplying creds.
    case parkedAwaitingProviderConfig
    /// All steps verified, but the handoff `status` round-trip has not yet succeeded —
    /// still Layer A.
    case awaitingHandoff
    /// The first successful `status` round-trip fired — Layer A is done, Layer B takes over.
    case handedOff
}

/// The result of a single bootstrap `run()`.
public struct BootstrapResult: Equatable, Sendable {
    public let phase: BootstrapPhase
    public let stepOutcomes: [BootstrapStepOutcome]

    public init(phase: BootstrapPhase, stepOutcomes: [BootstrapStepOutcome]) {
        self.phase = phase
        self.stepOutcomes = stepOutcomes
    }

    /// True only when Layer A handed off to the agent.
    public var didHandOff: Bool { phase == .handedOff }

    /// Human-facing, seam-free product copy.
    ///
    /// COHESIVE-PRODUCT CONTRACT: never exposes a CLI seam (`ouro`, `daemon`, `hatch`, a
    /// raw `--flag`). Those verbs live only in `BootstrapStepOutcome.auditDetail`.
    public var humanFacingLine: String {
        switch phase {
        case .failedInvalidAgent:
            return "Workbench couldn't identify your agent. Please reopen Workbench to try again."
        case .failedStep:
            return "Workbench couldn't finish bringing your agent online. You can try again — and if it keeps happening, reconnecting your provider usually clears it up."
        case .parkedAwaitingProviderConfig:
            return "Your agent needs you to connect a provider before it can come online."
        case .awaitingHandoff:
            return "Bringing your agent online…"
        case .handedOff:
            return "Your agent is online."
        }
    }
}

// MARK: - Step effects

/// The S0/S2–S5 step effects, each INJECTED as a closure so the machine unit-tests with
/// fakes — no live daemon/agent/process. Each agent-targeted effect receives the EXPLICIT
/// resolved agent name. Each effect returns its own post-effect verify health (S0/S3/S4/S5)
/// or, for S2, the provider-credential gate status.
public struct BootstrapStepEffects: Sendable {
    /// S0 — ensure the daemon; returns its post-effect verify health.
    public var ensureDaemon: @Sendable () async -> StepHealth
    /// S1 — ensure a usable agent exists; receives the explicit resolved name.
    public var ensureAgentExists: @Sendable (String) async -> StepHealth
    /// S2 — the human gate; returns the provider-credential status (parks on absent/declined).
    public var providerConfig: @Sendable () async -> ProviderCredentialStatus
    /// S3 — vault/provider sync; receives the explicit resolved name.
    public var vaultSync: @Sendable (String) async -> StepHealth
    /// S4 — verify credentials; receives the explicit resolved name.
    public var verifyCredentials: @Sendable (String) async -> StepHealth
    /// S5 — register the Workbench MCP for the boss; receives the explicit resolved name.
    public var registerWorkbenchMCP: @Sendable (String) async -> StepHealth
    /// Handoff edge — the `BossAgentMCPClient.status(agentName:)` round-trip; receives the
    /// explicit resolved name and returns `true` on the first successful round-trip.
    public var statusPing: @Sendable (String) async -> Bool

    public init(
        ensureDaemon: @escaping @Sendable () async -> StepHealth,
        ensureAgentExists: @escaping @Sendable (String) async -> StepHealth,
        providerConfig: @escaping @Sendable () async -> ProviderCredentialStatus,
        vaultSync: @escaping @Sendable (String) async -> StepHealth,
        verifyCredentials: @escaping @Sendable (String) async -> StepHealth,
        registerWorkbenchMCP: @escaping @Sendable (String) async -> StepHealth,
        statusPing: @escaping @Sendable (String) async -> Bool
    ) {
        self.ensureDaemon = ensureDaemon
        self.ensureAgentExists = ensureAgentExists
        self.providerConfig = providerConfig
        self.vaultSync = vaultSync
        self.verifyCredentials = verifyCredentials
        self.registerWorkbenchMCP = registerWorkbenchMCP
        self.statusPing = statusPing
    }
}

// MARK: - The pure state machine

/// A PURE, injectable Layer-A cold-start bootstrap state machine (S0→S5 + handoff edge).
///
/// All side effects are injected closures, so this unit-tests with fakes (no live
/// daemon/agent/process). The machine:
///   1. guards the EXPLICIT resolved agent name up front (wrong-agent guard),
///   2. runs S0→S5 in order, halting on any step whose post-effect verify does not pass
///      (recovery-truth — never assume success),
///   3. PARKS at S2 if the human gate has no usable credentials (stable, no busy-loop —
///      a single gate check, whose only exit is the human supplying creds), and
///   4. reports `handedOff` ONLY on the first successful `status` round-trip.
public struct AgentReadinessBootstrap: Sendable {
    public var context: BootstrapAgentContext
    public var effects: BootstrapStepEffects

    public init(context: BootstrapAgentContext, effects: BootstrapStepEffects) {
        self.context = context
        self.effects = effects
    }

    /// Run the machine once, returning the phase it settled into and the per-step
    /// recovery-truth outcomes. Re-running is the only way to leave a parked state: the
    /// caller invokes `run()` again AFTER the human supplies credentials.
    public func run() async -> BootstrapResult {
        // Wrong-agent guard: never let any step target an unresolved/implicit agent name.
        guard context.hasValidAgentName else {
            return BootstrapResult(phase: .failedInvalidAgent, stepOutcomes: [])
        }

        let name = context.agentName
        var outcomes: [BootstrapStepOutcome] = []

        // S0 — ensure daemon.
        if let failure = await runHealthStep(.ensureDaemon, into: &outcomes, { await effects.ensureDaemon() }) {
            return failure
        }

        // S1 — ensure agent exists.
        if let failure = await runHealthStep(.ensureAgentExists, into: &outcomes, { await effects.ensureAgentExists(name) }) {
            return failure
        }

        // S2 — provider-config human gate. Checked EXACTLY ONCE; parks (no busy-loop) on
        // absent/declined. The only exit from park is the human supplying creds + a re-run.
        let credentialStatus = await effects.providerConfig()
        guard credentialStatus.advances else {
            return BootstrapResult(phase: .parkedAwaitingProviderConfig, stepOutcomes: outcomes)
        }
        outcomes.append(BootstrapStepOutcome(step: .providerConfig, recovery: .verified))

        // S3 — vault / provider sync.
        if let failure = await runHealthStep(.vaultSync, into: &outcomes, { await effects.vaultSync(name) }) {
            return failure
        }

        // S4 — verify credentials.
        if let failure = await runHealthStep(.verifyCredentials, into: &outcomes, { await effects.verifyCredentials(name) }) {
            return failure
        }

        // S5 — register the Workbench MCP.
        if let failure = await runHealthStep(.registerWorkbenchMCP, into: &outcomes, { await effects.registerWorkbenchMCP(name) }) {
            return failure
        }

        // Handoff edge — only the FIRST successful status round-trip ends Layer A.
        let reachable = await effects.statusPing(name)
        let phase: BootstrapPhase = reachable ? .handedOff : .awaitingHandoff
        return BootstrapResult(phase: phase, stepOutcomes: outcomes)
    }

    /// Run one health-returning step, append its recovery-truth outcome, and return a halt
    /// result if it did not verify (recovery-truth — the machine never advances on a
    /// non-verified step). Returns `nil` when the step verified and the machine may advance.
    private func runHealthStep(
        _ step: BootstrapStep,
        into outcomes: inout [BootstrapStepOutcome],
        _ effect: () async -> StepHealth
    ) async -> BootstrapResult? {
        let health = await effect()
        let recovery = BootstrapRecoveryTruth.classify(health)
        outcomes.append(BootstrapStepOutcome(step: step, recovery: recovery))
        guard recovery.didVerify else {
            return BootstrapResult(phase: .failedStep(step), stepOutcomes: outcomes)
        }
        return nil
    }
}

// MARK: - S1 command construction (headless hatch / clone)

/// A credential flavor passed to a headless `ouro hatch`. These reach `hatch` via argv
/// (the interim cold-start sink); the credential string is carried only to build the
/// command tokens — it is NEVER routed through an agent's context.
public enum BootstrapHatchCredential: Equatable, Sendable {
    case apiKey(String)
    case setupToken(String)
    case oauthToken(String)
    case endpoint(endpoint: String, deployment: String)

    /// The argv flag/value tokens for this credential flavor.
    fileprivate var tokens: [String] {
        switch self {
        case let .apiKey(value):
            return ["--api-key", value]
        case let .setupToken(value):
            return ["--setup-token", value]
        case let .oauthToken(value):
            return ["--oauth-token", value]
        case let .endpoint(endpoint, deployment):
            return ["--endpoint", endpoint, "--deployment", deployment]
        }
    }
}

/// A built (but NOT executed) provision command for S1 ensure-agent-exists.
public struct BootstrapAgentProvisionPlan: Equatable, Sendable {
    public var tokens: [String]

    public init(tokens: [String]) {
        self.tokens = tokens
    }

    /// A shell-safe command line for audit/debug surfaces (raw `ouro` verbs allowed here).
    public var commandLine: String {
        ShellArgumentEscaper.commandLine(tokens)
    }
}

/// Builds the headless `ouro hatch` / `ouro clone` commands for S1. Pure command
/// CONSTRUCTION only — execution is injected separately, so nothing here runs a process.
public enum BootstrapAgentProvisionCommand {

    /// Build a headless `ouro hatch --agent <X> --human <Y> --provider <P>` + cred flags.
    ///
    /// The agent name carries the EXPLICIT resolved name and is validated as a usable bundle
    /// name (wrong-agent guard); human/provider must be non-empty. Throws rather than emit a
    /// command targeting an unresolved/invalid agent.
    public static func hatch(
        agentName: String,
        humanName: String,
        provider: String,
        credential: BootstrapHatchCredential
    ) throws -> BootstrapAgentProvisionPlan {
        let trimmedAgent = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAgent.isEmpty else {
            throw OuroAgentInstallCommandError.emptyAgentName
        }
        guard BossWorkbenchMCPRegistrar.isValidAgentBundleName(trimmedAgent) else {
            throw OuroAgentInstallCommandError.invalidAgentName(trimmedAgent)
        }
        let trimmedHuman = humanName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHuman.isEmpty else {
            throw OuroAgentInstallCommandError.invalidAgentName("empty human name")
        }
        let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProvider.isEmpty else {
            throw OuroAgentInstallCommandError.invalidAgentName("empty provider")
        }

        var tokens = [
            "ouro", "hatch",
            "--agent", trimmedAgent,
            "--human", trimmedHuman,
            "--provider", trimmedProvider,
        ]
        tokens += credential.tokens
        return BootstrapAgentProvisionPlan(tokens: tokens)
    }

    /// Build a headless `ouro clone <remote>` command.
    public static func clone(remote: String) throws -> BootstrapAgentProvisionPlan {
        let trimmedRemote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRemote.isEmpty else {
            throw OuroAgentInstallCommandError.emptyRemote
        }
        return BootstrapAgentProvisionPlan(tokens: ["ouro", "clone", trimmedRemote])
    }
}

// MARK: - S1 effect (build + injected-execute + post-effect verify)

/// The S1 ensure-agent-exists effect, modeled as build-command → injected-execute →
/// post-effect verify. Recovery-truth comes from the verify, never the executor's exit.
///
/// This is the composable building block the app wires into `BootstrapStepEffects.ensureAgentExists`.
/// The `execute` closure is what the app points at a real process runner; tests inject a
/// no-op, so the machine never actually runs `ouro hatch`.
public struct BootstrapAgentExistsEffect: Sendable {
    /// Whether a usable agent bundle already exists (skip provision when true).
    public var existingAgentIsUsable: @Sendable () async -> Bool
    /// Build the provision command (hatch/clone). May throw on invalid input.
    public var provisionCommand: @Sendable () throws -> BootstrapAgentProvisionPlan
    /// Execute the built command (INJECTED — does not actually run hatch in tests).
    public var execute: @Sendable (BootstrapAgentProvisionPlan) async throws -> Void
    /// Post-effect verify — the SOLE source of recovery truth; receives the resolved name.
    public var verify: @Sendable (String) async -> StepHealth

    public init(
        existingAgentIsUsable: @escaping @Sendable () async -> Bool,
        provisionCommand: @escaping @Sendable () throws -> BootstrapAgentProvisionPlan,
        execute: @escaping @Sendable (BootstrapAgentProvisionPlan) async throws -> Void,
        verify: @escaping @Sendable (String) async -> StepHealth
    ) {
        self.existingAgentIsUsable = existingAgentIsUsable
        self.provisionCommand = provisionCommand
        self.execute = execute
        self.verify = verify
    }

    /// Run the S1 effect for the explicit resolved agent name.
    ///
    /// - If a usable agent already exists, skip provision and verify.
    /// - Otherwise build + execute the provision command, then verify.
    /// - A thrown build/execute does NOT crash the step; it surfaces `.needsManual`
    ///   (an honest "couldn't provision automatically" — never a false success).
    public func run(agentName: String) async -> StepHealth {
        if await existingAgentIsUsable() {
            return await verify(agentName)
        }
        do {
            let plan = try provisionCommand()
            try await execute(plan)
        } catch {
            return .needsManual
        }
        return await verify(agentName)
    }
}
