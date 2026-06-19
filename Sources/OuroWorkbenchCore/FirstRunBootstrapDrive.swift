import Foundation

// MARK: - Per-step human-facing active copy

extension BootstrapStep {
    /// The seam-free, human-facing "in progress" line for this step — the cohesive-product
    /// voice the first-run UI shows while the step is running.
    ///
    /// COHESIVE-PRODUCT CONTRACT: never exposes a CLI seam (`ouro`, `daemon`, `hatch`, `vault`,
    /// `mcp`, a raw `--flag`). The raw verbs live ONLY in `auditLabel` / `BootstrapStepOutcome`.
    /// Workbench + the agent are ONE product: "your agent", "getting your agent ready".
    public var humanFacingActiveLine: String {
        switch self {
        case .ensureDaemon:
            return "Bringing Workbench online…"
        case .ensureAgentExists:
            return "Setting up your agent…"
        case .providerConfig:
            return "Connect a provider so your agent can start working."
        case .vaultSync:
            return "Syncing your agent's connection…"
        case .verifyCredentials:
            return "Checking your agent's connection…"
        case .registerWorkbenchMCP:
            return "Connecting your agent to Workbench…"
        }
    }
}

// MARK: - Per-step run state

/// The lifecycle state of a single bootstrap step as the first-run UI renders it.
///
/// Distinct from `BootstrapRecoveryTruth` (the machine's post-effect classification): this is
/// the *presentation* state, which also models steps that have not run yet (`pending`), the one
/// currently executing (`active`), and the human gate (`awaitingHuman`).
public enum BootstrapStepRunState: String, Codable, Equatable, Sendable {
    /// Not reached yet.
    case pending
    /// Currently executing.
    case active
    /// Post-effect verify passed — genuinely done.
    case verified
    /// Post-effect verify did not pass — the machine halted here (terminal failure, honest).
    case halted
    /// The S2 human gate is parked awaiting the human (the one human touchpoint).
    case awaitingHuman
    /// Skipped because an earlier step already satisfied it (reserved for future fan-out).
    case skipped
}

// MARK: - Step row view-model

/// A single first-run step row the UI renders: a seam-free human line + a raw audit line.
public struct BootstrapStepProgress: Equatable, Identifiable, Sendable {
    public let step: BootstrapStep
    public let state: BootstrapStepRunState

    public init(step: BootstrapStep, state: BootstrapStepRunState) {
        self.step = step
        self.state = state
    }

    public var id: String { step.rawValue }

    public var isActive: Bool { state == .active }
    public var isDone: Bool { state == .verified }
    public var isTerminalFailure: Bool { state == .halted }
    public var isAwaitingHuman: Bool { state == .awaitingHuman }

    /// The seam-free human line for this row. Active steps read as in-progress; done steps as
    /// complete; halted as an honest snag; the provider gate as the human ask. COHESIVE-PRODUCT:
    /// never leaks a CLI seam.
    public var humanFacingLine: String {
        switch state {
        case .pending:
            return step.humanFacingActiveLine
        case .active:
            return step.humanFacingActiveLine
        case .verified:
            return Self.doneLine(for: step)
        case .halted:
            return "Workbench couldn't finish bringing your agent online. You can try again — and if it keeps happening, reconnecting your provider usually clears it up."
        case .awaitingHuman:
            return step.humanFacingActiveLine
        case .skipped:
            return Self.doneLine(for: step)
        }
    }

    /// The raw audit/debug detail — the ONE place an `ouro` verb is allowed. Mirrors the step's
    /// audit label so the debug lane has one source of truth.
    public var auditDetail: String {
        "\(step.auditLabel): \(state.rawValue)"
    }

    private static func doneLine(for step: BootstrapStep) -> String {
        switch step {
        case .ensureDaemon:
            return "Workbench is online."
        case .ensureAgentExists:
            return "Your agent is set up."
        case .providerConfig:
            return "Provider connected."
        case .vaultSync:
            return "Your agent's connection is synced."
        case .verifyCredentials:
            return "Your agent's connection checks out."
        case .registerWorkbenchMCP:
            return "Your agent is connected to Workbench."
        }
    }
}

// MARK: - First-run UI mode

/// The first-run UI mode the app renders, derived purely from a `BootstrapPhase`.
///
/// This is the LAYER SWITCH: `.bootstrapping` / `.parkedAwaitingProvider` / `.needsAttention`
/// are all Layer A (native cold-start bootstrap); `.agentDriven` is Layer B (the healthy boss
/// drives the UI). The handoff edge is the `.agentDriven` transition — `didHandOff` is true only
/// there.
public enum FirstRunMode: String, CaseIterable, Codable, Equatable, Sendable {
    /// Layer A: the native bootstrap is running its steps; show live per-step progress.
    case bootstrapping
    /// Layer A parked at the S2 human gate; surface the native provider form (the one touchpoint).
    case parkedAwaitingProvider
    /// Layer A could not complete a step automatically (or the agent name was invalid) — honest
    /// manual-recovery surface; never a false "ready".
    case needsAttention
    /// Layer B: the bootstrap handed off; the healthy boss now drives the UI via the onboarding
    /// action family. The human is never asked to run anything from here on.
    case agentDriven

    /// Map a settled bootstrap phase to the UI mode.
    public init(phase: BootstrapPhase) {
        switch phase {
        case .handedOff:
            self = .agentDriven
        case .parkedAwaitingProviderConfig:
            self = .parkedAwaitingProvider
        case .awaitingHandoff:
            // All steps verified but the handoff round-trip has not succeeded yet — still
            // Layer A, still "bringing your agent online".
            self = .bootstrapping
        case .failedStep, .failedInvalidAgent:
            self = .needsAttention
        }
    }

    /// True only for the agent-driven mode — the single mode that crossed the handoff edge.
    public var didHandOff: Bool { self == .agentDriven }

    /// True only for the parked mode — the single mode that surfaces the native provider gate.
    public var opensProviderGate: Bool { self == .parkedAwaitingProvider }

    /// The seam-free product headline for this mode.
    public var headline: String {
        switch self {
        case .bootstrapping:
            return "Workbench is getting your agent ready…"
        case .parkedAwaitingProvider:
            return "Connect a provider to bring your agent online"
        case .needsAttention:
            return "Workbench needs a moment with your agent"
        case .agentDriven:
            return "Your agent is online and finishing setup"
        }
    }
}

// MARK: - The drive presenter

/// The aggregate first-run presentation: the ordered step rows + the UI mode + the headline.
public struct FirstRunBootstrapPresentation: Equatable, Sendable {
    public let mode: FirstRunMode
    public let rows: [BootstrapStepProgress]
    public let headline: String

    public init(mode: FirstRunMode, rows: [BootstrapStepProgress], headline: String) {
        self.mode = mode
        self.rows = rows
        self.headline = headline
    }

    /// True when the UI should surface the native provider form (the one human gate).
    public var opensProviderGate: Bool { mode.opensProviderGate }
    /// True when Layer A handed off and Layer B (agent-driven) takes the wheel.
    public var didHandOff: Bool { mode.didHandOff }
}

/// PURE presenter that turns a `BootstrapResult` (+ the currently-active step, if mid-run) into
/// the ordered first-run step rows and the UI mode. The SwiftUI view layer is thin wiring over
/// this; ALL the branching / sequencing / copy lives here so it unit-tests without a live
/// daemon/agent. Mirrors the Slice 0/2/3 pure-Core-with-tests pattern.
public struct FirstRunBootstrapDrive: Sendable {
    public init() {}

    /// The seam-free narration the UI shows the instant Layer A hands off to Layer B: the
    /// healthy boss now inspects (`workbench_onboarding_status`), remediates (issues onboarding
    /// actions), and narrates — the human is never asked to run anything. Product voice, so
    /// seam-free.
    public static let agentDrivenHandoffNarration =
        "Your agent is online and taking over from here — it's checking everything is set up and will let you know if it needs you."

    /// The pure run/skip decision for `startFirstRunBootstrapIfNeeded`. Start the bootstrap only
    /// when:
    ///   - setup is NOT already ready (a ready setup has nothing to bootstrap), AND
    ///   - a boss is explicitly resolved (never bootstrap an unresolved/implicit agent), AND
    ///   - the bootstrap is not already running (no re-entrancy), AND
    ///   - the current mode is not already `.agentDriven` (after handoff the agent drives — never
    ///     re-enter Layer A from a view re-appear).
    ///
    /// `.parkedAwaitingProvider` and `.needsAttention` ARE re-runnable: a re-appear after the
    /// human submits the provider form (or after a transient snag) re-runs the post-form probe and
    /// can cross the gate / recover.
    public static func shouldStart(
        isReady: Bool,
        hasResolvedBoss: Bool,
        isRunning: Bool,
        currentMode: FirstRunMode?
    ) -> Bool {
        guard !isReady, hasResolvedBoss, !isRunning else { return false }
        if currentMode == .agentDriven { return false }
        return true
    }

    /// Present an idle first-run (no bootstrap run yet): all steps pending, bootstrapping mode.
    public func presentIdle() -> FirstRunBootstrapPresentation {
        let rows = BootstrapStep.allCases.map { BootstrapStepProgress(step: $0, state: .pending) }
        let mode = FirstRunMode.bootstrapping
        return FirstRunBootstrapPresentation(mode: mode, rows: rows, headline: mode.headline)
    }

    /// Present the result of a bootstrap run.
    ///
    /// `activeStep` is the step currently executing (mid-run); pass `nil` for a settled result.
    /// Rows are always in canonical S0→S5 order. A step's row state is derived from:
    ///   - its recovery-truth outcome if it ran and was classified, OR
    ///   - `active` if it's the `activeStep`, OR
    ///   - `awaitingHuman` if the machine parked at the provider gate and this is S2, OR
    ///   - `pending` otherwise (not reached).
    public func present(result: BootstrapResult, activeStep: BootstrapStep?) -> FirstRunBootstrapPresentation {
        let mode = FirstRunMode(phase: result.phase)

        // Index the per-step recovery outcomes for O(1) lookup.
        var recoveryByStep: [BootstrapStep: BootstrapRecoveryTruth] = [:]
        for outcome in result.stepOutcomes {
            recoveryByStep[outcome.step] = outcome.recovery
        }

        let parkedAtProvider = (result.phase == .parkedAwaitingProviderConfig)

        let rows = BootstrapStep.allCases.map { step -> BootstrapStepProgress in
            if let recovery = recoveryByStep[step] {
                // A classified step: verified advances; anything else halted at that step.
                let state: BootstrapStepRunState = recovery.didVerify ? .verified : .halted
                return BootstrapStepProgress(step: step, state: state)
            }
            if parkedAtProvider, step == .providerConfig {
                return BootstrapStepProgress(step: step, state: .awaitingHuman)
            }
            if let activeStep, step == activeStep {
                return BootstrapStepProgress(step: step, state: .active)
            }
            return BootstrapStepProgress(step: step, state: .pending)
        }

        return FirstRunBootstrapPresentation(mode: mode, rows: rows, headline: mode.headline)
    }
}
