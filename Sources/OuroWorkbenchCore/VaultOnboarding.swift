import Foundation

/// F13 — in-app vault onboarding: the `.needsVaultSetup` cold-start recovery path.
///
/// After F1, a fresh agent's headless `ouro hatch` writes the bundle but the vault step throws
/// (it needs a TTY secret), so the credential never persists and `classifyColdStart` returns
/// `.needsVaultSetup`. The provider credential the user typed is gone and un-replayable (it
/// reached `ouro hatch` only as ephemeral argv; re-running hatch hard-errors; `ouro auth`
/// re-prompts AND needs the vault first). So F13 cannot persist silently — it re-collects the
/// credential by running the CLI's documented recovery chain in a native Workbench terminal (a
/// real TTY), then re-probes and, on `.working`, hands back to F1's `.ready` path.
///
/// This file is the PURE seam: the decision of whether to offer, the fold from terminal-exit +
/// re-probe verdict into the next state (with F1's safety invariant), the exact recovery command
/// chain, and the seam-free human copy. All I/O (running the terminal, re-probing) lives in the
/// App, which is a thin wiring layer over these pure values.

/// The lifecycle of an in-app vault-onboarding attempt.
public enum VaultOnboardingState: Equatable, Sendable {
    /// We've offered "Finish setup"; the human still needs to enter the unlock secret.
    case needsSecret
    /// The native recovery terminal is running (the human is entering the secret + credential).
    case runningVaultTerminal
    /// The terminal exited cleanly; we're re-probing to confirm the credential persisted.
    case persisting
    /// The re-probe positively confirmed the agent is working — hand back to F1's ready path.
    case ready
    /// The attempt could not be completed; carries why (retryable).
    case failed(reason: VaultOnboardingFailure)
}

/// Why an in-app vault-onboarding attempt could not reach `.ready`. Stable `rawValue` for the
/// audit log (NOT human copy — `VaultOnboardingMachine.humanLine` is the human surface).
public enum VaultOnboardingFailure: String, Equatable, Sendable {
    /// The recovery terminal command exited non-zero.
    case vaultCommandNonZeroExit
    /// The recovery terminal never launched at all.
    case vaultCommandLaunchError
    /// The chain exited cleanly but the re-probe says the provider still isn't connected
    /// (vault still locked / unauthorized) — retryable.
    case stillNotConnected
    /// The chain exited cleanly but we can't positively confirm (network-unreachable,
    /// ambiguous output, or the probe itself timed out) — retryable.
    case couldNotConfirm
}

/// The pure state machine behind in-app vault onboarding. No I/O: every method is a total
/// function over its inputs, so the App wiring stays a thin fold.
public struct VaultOnboardingMachine: Sendable {
    public init() {}

    /// Only offer "Finish setup" for the honest needs-vault case. A `.ready` agent is already
    /// connected; a `.failed` cold-start never produced a recoverable bundle.
    public static func shouldOffer(coldStart: ColdStartOutcome) -> Bool {
        coldStart == .needsVaultSetup
    }

    /// Fold the recovery-terminal exit + the re-probe verdict into the next state.
    ///
    /// - `vaultExitCode`: the terminal's exit code, or `nil` when the terminal never launched.
    /// - `reprobeVerdict`: the `ProviderCheckClassifier` verdict, or `nil` when the probe timed
    ///   out / couldn't run.
    ///
    /// SAFETY INVARIANT (mirror F1's `classifyColdStart`): NEVER `.ready` unless the re-probe
    /// positively returns `.working`. A clean exit (code 0) alone is not ready — the chain can
    /// exit 0 with a wedged daemon, so the re-probe is the sole authority on `.ready`.
    public static func afterVaultTerminal(
        vaultExitCode: Int32?,
        reprobeVerdict: ProviderConnectionVerdict?
    ) -> VaultOnboardingState {
        guard let code = vaultExitCode else {
            return .failed(reason: .vaultCommandLaunchError)
        }
        guard code == 0 else {
            return .failed(reason: .vaultCommandNonZeroExit)
        }
        switch reprobeVerdict {
        case .working:
            return .ready
        case .vaultLocked, .unauthorized:
            return .failed(reason: .stillNotConnected)
        case .unreachable, .indeterminate, .none:
            return .failed(reason: .couldNotConfirm)
        }
    }

    /// Seam-free human copy for a state — names the agent, never leaks `ouro`/`vault`/`hatch`/
    /// argv flags. Returns a line for every state.
    public static func humanLine(for state: VaultOnboardingState, agentName: String) -> String? {
        switch state {
        case .needsSecret:
            return "Finish connecting \(agentName): you'll set an unlock secret and re-enter your provider details."
        case .runningVaultTerminal:
            return "Finishing setup for \(agentName) — follow the prompts in the window that just opened."
        case .persisting:
            return "Checking that \(agentName) is connected…"
        case .ready:
            return "\(agentName) is connected and ready."
        case let .failed(reason):
            switch reason {
            case .vaultCommandLaunchError:
                return "Workbench couldn't open the setup window for \(agentName). Please try again."
            case .vaultCommandNonZeroExit:
                return "Setup for \(agentName) didn't complete. Please try again."
            case .stillNotConnected:
                return "\(agentName) still isn't connected. Re-enter your provider details and try again."
            case .couldNotConfirm:
                return "Workbench couldn't confirm \(agentName) is connected yet. Please try again."
            }
        }
    }
}

/// Builds the chained recovery command line for the native terminal.
public enum VaultOnboardingCommand {
    /// The chained recovery command for the native terminal:
    ///
    /// ```
    /// ouro vault create --agent <name> --email <email> && ouro auth --agent <name> --provider <p> && ouro provider refresh --agent <name>
    /// ```
    ///
    /// (`ouro vault create` alone is NOT enough — it makes the vault account but stores no
    /// provider credential, so the chain must also run `ouro auth` + `ouro provider refresh`.)
    ///
    /// `email` defaults to `<name>@ouro.bot` (the agent's vault-account email). Every argument is
    /// quoted via `ShellArgumentEscaper`; the ` && ` separators between the three `ouro`
    /// invocations are literal and never quoted.
    public static func finishSetupCommandLine(
        agentName: String,
        providerFlag: String,
        email: String?
    ) -> String {
        let resolvedEmail = email ?? "\(agentName)@ouro.bot"
        let vaultCreate = ShellArgumentEscaper.commandLine(
            ["ouro", "vault", "create", "--agent", agentName, "--email", resolvedEmail]
        )
        let auth = ShellArgumentEscaper.commandLine(
            ["ouro", "auth", "--agent", agentName, "--provider", providerFlag]
        )
        let refresh = ShellArgumentEscaper.commandLine(
            ["ouro", "provider", "refresh", "--agent", agentName]
        )
        return [vaultCreate, auth, refresh].joined(separator: " && ")
    }

    /// F6 — the chained credential-ROTATION command for an EXISTING agent's native terminal:
    ///
    /// ```
    /// ouro vault unlock --agent <name> && ouro auth --agent <name> --provider <p> && ouro provider refresh --agent <name>
    /// ```
    ///
    /// An existing agent's vault ALREADY exists, so rotation UNLOCKS it (it does NOT `create` it,
    /// which would be the cold-start `finishSetupCommandLine` path), and carries NO `--email` (the
    /// vault account is already provisioned — only `vault create` takes the account email). Like
    /// F13's chain there is still no non-interactive `ouro` credential-set sink, so `auth` must run
    /// in a real TTY where the human re-enters the unlock secret + the provider credential; this is
    /// why F6 drives the chain in a native Workbench terminal rather than persisting silently.
    ///
    /// Every argument is quoted via `ShellArgumentEscaper`; the ` && ` separators between the three
    /// `ouro` invocations are literal and never quoted (mirrors `finishSetupCommandLine`).
    public static func rotateCredentialCommandLine(
        agentName: String,
        providerFlag: String
    ) -> String {
        let vaultUnlock = ShellArgumentEscaper.commandLine(
            ["ouro", "vault", "unlock", "--agent", agentName]
        )
        let auth = ShellArgumentEscaper.commandLine(
            ["ouro", "auth", "--agent", agentName, "--provider", providerFlag]
        )
        let refresh = ShellArgumentEscaper.commandLine(
            ["ouro", "provider", "refresh", "--agent", agentName]
        )
        return [vaultUnlock, auth, refresh].joined(separator: " && ")
    }
}
