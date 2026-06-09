import Foundation

/// Pure decision logic for resolving the REAL bootstrap step inputs from already-scanned app
/// state (the agent inventory + the MCP-registration snapshot).
///
/// The app injects thin closures into `BootstrapStepEffects` that wrap these pure resolvers, so
/// the load-bearing branching — does a usable agent exist (S1), are creds present (the S2 gate),
/// is the MCP registered (S5) — unit-tests WITHOUT a live daemon/agent. This mirrors the
/// Slice 0/1/2/3 "pure-Core decision + injected real effect" split.
///
/// COLD-START COMPOSITION NOTE (load-bearing): S1 runs BEFORE the S2 provider gate, but a
/// cold-start `ouro hatch` needs a credential that only the S2 form supplies. So S1 cannot hatch
/// pre-gate. The resolution: when no usable agent exists yet, S1's verify reads `.healthy` (it
/// does NOT halt the run) so the machine REACHES the gate; the gate then reads `.absent` (no
/// creds) and the machine PARKS. The provider form is the cold-start hatch sink that creates the
/// agent WITH the credential; on the post-submit re-run, S1 verifies the now-real agent truthfully
/// and the gate reads `credentialsPresent`. The honest "agent not created yet" signal therefore
/// lives in the gate's park — never a false S1 success claiming the agent is ready.
public enum FirstRunBootstrapEffectsResolver {

    /// Whether a usable (`.ready`, valid-bundle-named) agent with `name` exists in `agents`.
    public static func usableAgentExists(named name: String, in agents: [OuroAgentRecord]) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return agents.contains { record in
            record.name.caseInsensitiveCompare(trimmed) == .orderedSame && record.isUsableAsBoss
        }
    }

    /// The S1 ensure-agent-exists health. Always `.healthy`: an existing usable agent verifies
    /// trivially, and an absent agent DEFERS creation to the S2 gate (which then parks on absent
    /// creds — the honest "not created yet" signal). S1 has no credential to hatch with pre-gate,
    /// so it must not halt the run before the gate; recovery truth for the cold-start agent is
    /// established on the post-submit re-run. See the type doc's cold-start note. `name` / `agents`
    /// are part of the effect signature (the machine passes the explicit resolved name) and are
    /// validated by the gate; this step itself does not branch on them.
    public static func ensureAgentExistsHealth(named name: String, in agents: [OuroAgentRecord]) -> StepHealth {
        .healthy
    }

    /// The S2 provider-gate status, derived from whether the named agent has a usable provider in
    /// EITHER lane. `credentialsPresent` advances; `absent` parks (the only exit is the human
    /// supplying creds via the native form). Never returns `.declined` — that comes only from an
    /// explicit human dismissal of the form, surfaced by the app, not from this state read.
    public static func providerGateStatus(named name: String, in agents: [OuroAgentRecord]) -> ProviderCredentialStatus {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let agent = agents.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            // No bundle yet → cold start → creds absent → park at the gate.
            return .absent
        }
        let hasProvider = agent.humanFacing?.provider != nil || agent.agentFacing?.provider != nil
        return hasProvider ? .credentialsPresent : .absent
    }

    /// The S5 Workbench-tools-availability health from a registration snapshot status. Under the
    /// RUNTIME-INJECTION model `.registered` means "the Workbench MCP binary is present (runtime
    /// injection available) AND the bundle is clean of any stale entry" — the only `.healthy`.
    /// Anything else is `.stillDegraded` (cleanup-pending re-attempts; binary-missing/structural
    /// failures halt honestly — never a false "done").
    public static func registrationHealth(_ status: BossWorkbenchMCPRegistrationStatus) -> StepHealth {
        status == .registered ? .healthy : .stillDegraded
    }
}
